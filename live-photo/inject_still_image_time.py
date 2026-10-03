#!/usr/bin/env python3
"""Inject Apple Live Photo still-image-time mebx track into a QuickTime MOV."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


def be32(n: int) -> bytes:
    return struct.pack(">I", n & 0xFFFFFFFF)


def be16(n: int) -> bytes:
    return struct.pack(">H", n & 0xFFFF)


def box(typ: bytes, payload: bytes) -> bytes:
    if len(typ) != 4:
        raise ValueError(typ)
    return be32(8 + len(payload)) + typ + payload


def read_boxes(data: bytes, start: int = 0, end: int | None = None) -> list[tuple[int, bytes, int, int]]:
    """Return list of (header_offset, type, content_offset, end_offset)."""
    if end is None:
        end = len(data)
    out = []
    p = start
    while p + 8 <= end:
        size = int.from_bytes(data[p : p + 4], "big")
        typ = bytes(data[p + 4 : p + 8])
        hdr = 8
        if size == 1:
            if p + 16 > end:
                break
            size = int.from_bytes(data[p + 8 : p + 16], "big")
            hdr = 16
        elif size == 0:
            size = end - p
        if size < hdr or p + size > end:
            break
        out.append((p, typ, p + hdr, p + size))
        p += size
    return out


def find_box(data: bytes, typ: bytes, start: int = 0, end: int | None = None):
    for off, t, content, box_end in read_boxes(data, start, end):
        if t == typ:
            return off, content, box_end
    return None


def add_delta_to_chunk_offsets(data: bytearray, delta: int) -> None:
    """Add delta to all stco/co64 offsets in the file (moov-level)."""
    moov = find_box(data, b"moov")
    if not moov:
        raise RuntimeError("moov not found")
    _, moov_c, moov_e = moov

    def walk(start: int, end: int) -> None:
        for off, typ, content, box_end in read_boxes(data, start, end):
            if typ in {b"trak", b"mdia", b"minf", b"stbl", b"edts", b"dinf"}:
                walk(content, box_end)
            elif typ == b"stco":
                # version/flags(4) + entry_count(4) + offsets
                count = int.from_bytes(data[content + 4 : content + 8], "big")
                p = content + 8
                for _ in range(count):
                    old = int.from_bytes(data[p : p + 4], "big")
                    data[p : p + 4] = be32(old + delta)
                    p += 4
            elif typ == b"co64":
                count = int.from_bytes(data[content + 4 : content + 8], "big")
                p = content + 8
                for _ in range(count):
                    old = int.from_bytes(data[p : p + 8], "big")
                    data[p : p + 8] = struct.pack(">Q", old + delta)
                    p += 8

    walk(moov_c, moov_e)


def build_still_image_time_trak(
    track_id: int,
    still_seconds: float,
    movie_timescale: int,
    sample_offset: int,
) -> bytes:
    meta_timescale = 600
    empty_dur = max(0, int(round(still_seconds * movie_timescale)))
    media_edit_dur = max(1, movie_timescale // meta_timescale)  # ~1 media tick in movie units
    track_dur = empty_dur + media_edit_dur

    # elst: empty edit delays presentation to still moment, then 1-tick media
    elst_payload = be32(0) + be32(2)
    elst_payload += be32(empty_dur) + struct.pack(">i", -1) + be32(0x00010000)
    elst_payload += be32(media_edit_dur) + be32(0) + be32(0x00010000)
    edts = box(b"edts", box(b"elst", elst_payload))

    # tkhd version 0
    tkhd_payload = bytearray()
    tkhd_payload += be32(0x000007)  # version/flags: track enabled+in movie+in preview
    tkhd_payload += be32(0) * 2  # creation/modification
    tkhd_payload += be32(track_id)
    tkhd_payload += be32(0)  # reserved
    tkhd_payload += be32(track_dur)
    tkhd_payload += be32(0) * 2  # reserved
    tkhd_payload += be16(0) + be16(0)  # layer, alternate group
    tkhd_payload += be16(0) + be16(0)  # volume, reserved
    # identity matrix
    tkhd_payload += struct.pack(
        ">9I",
        0x10000,
        0,
        0,
        0,
        0x10000,
        0,
        0,
        0,
        0x40000000,
    )
    tkhd_payload += be32(0) + be32(0)  # width/height
    tkhd = box(b"tkhd", bytes(tkhd_payload))

    # mdhd
    mdhd_payload = be32(0) + be32(0) * 2 + be32(meta_timescale) + be32(1) + be16(0x55C4) + be16(0)
    mdhd = box(b"mdhd", mdhd_payload)

    # hdlr meta
    hdlr_payload = be32(0) + b"meta" + be32(0) * 3 + b"\x00"
    hdlr = box(b"hdlr", hdlr_payload)

    # gmhd/gmin
    gmin = box(b"gmin", be32(0) + be16(0x40) + be16(0x8000) + be16(0x8000) + be16(0x8000) + be16(0))
    gmhd = box(b"gmhd", gmin)

    # data handler
    hdlr_data = box(b"hdlr", be32(0) + b"alis" + be32(0) * 3 + b"\x00")

    # dinf/dref
    url_ = box(b"url ", be32(1))  # self-contained flag
    dref = box(b"dref", be32(0) + be32(1) + url_)
    dinf = box(b"dinf", dref)

    # mebx sample entry with still-image-time key
    key_name = b"com.apple.quicktime.still-image-time"
    keyd = box(b"keyd", b"mdta" + key_name)
    keys = box(b"keys", be32(0) + be32(1) + keyd)
    # SampleEntry prefix: 6 reserved + data_reference_index=1
    mebx_payload = b"\x00" * 6 + be16(1) + keys
    mebx = box(b"mebx", mebx_payload)
    stsd = box(b"stsd", be32(0) + be32(1) + mebx)

    stts = box(b"stts", be32(0) + be32(1) + be32(1) + be32(1))
    stsc = box(b"stsc", be32(0) + be32(1) + be32(1) + be32(1) + be32(1))
    # 8-byte sample; last byte 0xFF == -1 int8 marker used by Apple
    sample_size = 8
    stsz = box(b"stsz", be32(0) + be32(0) + be32(1) + be32(sample_size))
    stco = box(b"stco", be32(0) + be32(1) + be32(sample_offset))
    stbl = box(b"stbl", stsd + stts + stsc + stsz + stco)

    minf = box(b"minf", gmhd + hdlr_data + dinf + stbl)
    mdia = box(b"mdia", mdhd + hdlr + minf)
    return box(b"trak", tkhd + edts + mdia)


def inject_still_image_time(mov_path: Path, still_seconds: float, output: Path | None = None) -> Path:
    data = bytearray(Path(mov_path).read_bytes())
    output = output or mov_path

    ftyp = find_box(data, b"ftyp")
    moov = find_box(data, b"moov")
    mdat = find_box(data, b"mdat")
    if not (ftyp and moov and mdat):
        raise RuntimeError("Expected ftyp/moov/mdat in MOV")

    moov_off, moov_c, moov_e = moov
    mdat_off, mdat_c, mdat_e = mdat

    # mvhd timescale + next track id (QuickTime / ISO layout)
    mvhd = find_box(data, b"mvhd", moov_c, moov_e)
    if not mvhd:
        raise RuntimeError("mvhd missing")
    _, mvhd_c, mvhd_e = mvhd
    version = data[mvhd_c]
    if version == 1:
        # ver/flags(4) creation(8) modification(8) timescale(4) duration(8) ... nextTrackID at end-4
        timescale = int.from_bytes(data[mvhd_c + 20 : mvhd_c + 24], "big")
    else:
        # ver/flags(4) creation(4) modification(4) timescale(4) duration(4) ...
        timescale = int.from_bytes(data[mvhd_c + 12 : mvhd_c + 16], "big")
    next_track_id_off = mvhd_e - 4
    next_track_id = int.from_bytes(data[next_track_id_off : next_track_id_off + 4], "big")
    if next_track_id <= 0:
        raise RuntimeError(f"invalid next_track_id={next_track_id}")
    print(f"mvhd timescale={timescale} next_track_id={next_track_id}")

    # Append sample to mdat first (doesn't shift moov if mdat is after moov)
    sample = b"\x00\x00\x00\x00\x00\x00\x00\xff"
    if mdat_off < moov_off:
        raise RuntimeError("Unsupported layout: mdat before moov")

    # Current sample will be at end of file after we append — but moov growth shifts mdat.
    # Strategy:
    # 1) Build trak with placeholder offset
    # 2) Insert trak into moov, compute moov growth delta
    # 3) Fix all chunk offsets by delta
    # 4) Append sample and set new track stco to final absolute offset

    placeholder_offset = 0
    trak = build_still_image_time_trak(next_track_id, still_seconds, timescale, placeholder_offset)

    # Insert trak at end of moov content
    insert_at = moov_e
    data[insert_at:insert_at] = trak
    moov_growth = len(trak)
    # Update moov size
    new_moov_size = (moov_e - moov_off) + moov_growth
    data[moov_off : moov_off + 4] = be32(new_moov_size)
    # Update next_track_id
    data[next_track_id_off : next_track_id_off + 4] = be32(next_track_id + 1)

    # Shift all chunk offsets because mdat moved forward by moov_growth
    add_delta_to_chunk_offsets(data, moov_growth)

    # Append sample bytes at end of mdat
    # mdat moved by moov_growth
    mdat_off += moov_growth
    mdat_c += moov_growth
    mdat_e += moov_growth
    old_mdat_size = int.from_bytes(data[mdat_off : mdat_off + 4], "big")
    sample_abs = len(data)  # will append at EOF; ensure mdat is last
    if mdat_e != len(data):
        # if something follows mdat, append inside mdat before end
        sample_abs = mdat_e
        data[mdat_e:mdat_e] = sample
        data[mdat_off : mdat_off + 4] = be32(old_mdat_size + len(sample))
    else:
        data.extend(sample)
        data[mdat_off : mdat_off + 4] = be32(old_mdat_size + len(sample))

    # Patch the new track's stco (last stco in file / in the track we added)
    # Find the last stco box and set its single offset.
    last_stco = None
    moov2 = find_box(data, b"moov")
    assert moov2
    _, mc, me = moov2

    def walk(start: int, end: int) -> None:
        nonlocal last_stco
        for off, typ, content, box_end in read_boxes(data, start, end):
            if typ in {b"trak", b"mdia", b"minf", b"stbl", b"edts", b"dinf"}:
                walk(content, box_end)
            elif typ == b"stco":
                last_stco = content

    walk(mc, me)
    if last_stco is None:
        raise RuntimeError("stco not found after inject")
    # version/flags + count + offset
    data[last_stco + 8 : last_stco + 12] = be32(sample_abs)

    Path(output).write_bytes(data)
    return Path(output)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mov", type=Path)
    ap.add_argument("--still-time", type=float, required=True, help="Still image time in seconds")
    ap.add_argument("-o", "--output", type=Path, default=None)
    args = ap.parse_args()
    out = inject_still_image_time(args.mov, args.still_time, args.output)
    print(f"Injected still-image-time={args.still_time}s into {out}")


if __name__ == "__main__":
    main()
