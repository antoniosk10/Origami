#!/usr/bin/env python3
"""Build an Apple Live Photo (JPG + MOV) from two still frames."""

from __future__ import annotations

import argparse
import shutil
import struct
import subprocess
import tempfile
import uuid
from pathlib import Path

import piexif
from PIL import Image

EXIFTOOL = Path("/tmp/exiftool-13.25/exiftool")

# Hard cut: first frame, then instantly second frame (no crossfade).
# 1.5s + 1.5s so Live Photo converters that key off the midpoint still see both.
DURATION_S = 3.0
DARK_HOLD_S = 1.5
BRIGHT_HOLD_S = 1.5
FPS = 30


def build_apple_makernote(content_id: str) -> bytes:
    """Apple MakerNote with tag 0x0011 = Live Photo ContentIdentifier."""
    payload = content_id.encode("ascii") + b"\x00"
    blob = bytearray()
    blob.extend(b"Apple iOS\x00")
    blob.extend(b"\x00\x01")  # version
    blob.extend(b"MM")  # big-endian TIFF
    blob.extend(struct.pack(">H", 1))  # one IFD entry
    value_offset = 16 + 12 + 4
    blob.extend(struct.pack(">HHII", 0x0011, 2, len(payload), value_offset))
    blob.extend(struct.pack(">I", 0))  # next IFD
    if len(blob) != value_offset:
        raise RuntimeError(f"MakerNote offset mismatch: {len(blob)} != {value_offset}")
    blob.extend(payload)
    return bytes(blob)


def write_live_jpeg(src: Path, dst: Path, content_id: str, size: tuple[int, int]) -> None:
    img = Image.open(src).convert("RGB")
    if img.size != size:
        img = img.resize(size, Image.Resampling.LANCZOS)

    zeroth = {
        piexif.ImageIFD.Make: b"Apple",
        piexif.ImageIFD.Model: b"iPhone 15 Pro",
        piexif.ImageIFD.Software: b"LivePhotoMaker",
        piexif.ImageIFD.Orientation: 1,
        piexif.ImageIFD.XResolution: (72, 1),
        piexif.ImageIFD.YResolution: (72, 1),
        piexif.ImageIFD.ResolutionUnit: 2,
    }
    exif_ifd = {
        piexif.ExifIFD.MakerNote: build_apple_makernote(content_id),
        piexif.ExifIFD.ColorSpace: 1,
        piexif.ExifIFD.PixelXDimension: size[0],
        piexif.ExifIFD.PixelYDimension: size[1],
    }
    exif_bytes = piexif.dump({"0th": zeroth, "Exif": exif_ifd})
    img.save(dst, "JPEG", quality=95, subsampling=0, exif=exif_bytes)


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def make_video(dark: Path, bright: Path, out_mov: Path, size: tuple[int, int], fps: int = FPS) -> None:
    """2.0s clip: hard cut from first frame to second (no crossfade)."""
    w, h = size
    w -= w % 2
    h -= h % 2
    frames = int(round(DURATION_S * fps))
    vf = (
        f"[0:v]scale={w}:{h}:flags=lanczos,setsar=1,fps={fps},format=yuv420p,"
        f"trim=duration={DARK_HOLD_S},setpts=PTS-STARTPTS[v0];"
        f"[1:v]scale={w}:{h}:flags=lanczos,setsar=1,fps={fps},format=yuv420p,"
        f"trim=duration={BRIGHT_HOLD_S},setpts=PTS-STARTPTS[v1];"
        f"[v0][v1]concat=n=2:v=1:a=0[v]"
    )
    # Silent audio helps some iOS Live Photo importers accept the MOV.
    run(
        [
            "ffmpeg",
            "-y",
            "-loop",
            "1",
            "-t",
            str(DARK_HOLD_S),
            "-i",
            str(dark),
            "-loop",
            "1",
            "-t",
            str(BRIGHT_HOLD_S),
            "-i",
            str(bright),
            "-f",
            "lavfi",
            "-i",
            "anullsrc=channel_layout=mono:sample_rate=44100",
            "-filter_complex",
            vf,
            "-map",
            "[v]",
            "-map",
            "2:a",
            "-c:v",
            "libx264",
            "-profile:v",
            "main",
            "-level:v",
            "5.1",
            "-bf",
            "0",
            "-g",
            str(max(1, int(round(DARK_HOLD_S * fps)))),  # keyframe on the cut
            "-keyint_min",
            "1",
            "-sc_threshold",
            "0",
            "-force_key_frames",
            f"expr:gte(t,{DARK_HOLD_S})",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-r",
            str(fps),
            "-frames:v",
            str(frames),
            "-c:a",
            "aac",
            "-b:a",
            "64k",
            "-shortest",
            "-movflags",
            "+faststart",
            "-tag:v",
            "avc1",
            "-brand",
            "qt  ",
            str(out_mov),
        ]
    )


def stamp_mov_content_id(mov: Path, content_id: str) -> None:
    if not EXIFTOOL.exists():
        raise FileNotFoundError(f"exiftool not found at {EXIFTOOL}")
    run(
        [
            str(EXIFTOOL),
            "-overwrite_original",
            f"-QuickTime:ContentIdentifier={content_id}",
            f"-Keys:ContentIdentifier={content_id}",
            str(mov),
        ]
    )


def verify(jpeg: Path, mov: Path, content_id: str) -> None:
    out = subprocess.check_output(
        [str(EXIFTOOL), "-s", "-ContentIdentifier", "-MakerNotes:ContentIdentifier", str(jpeg), str(mov)],
        text=True,
    )
    print(out)
    if content_id not in out:
        raise RuntimeError("ContentIdentifier was not written correctly")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dark", type=Path, required=True, help="Flashlight soft / dim frame")
    parser.add_argument("--bright", type=Path, required=True, help="Flashlight beam-on frame (key photo)")
    parser.add_argument("--outdir", type=Path, required=True)
    parser.add_argument("--basename", default="IMG_FLASH")
    parser.add_argument("--width", type=int, default=1170)
    parser.add_argument("--height", type=int, default=2084)
    args = parser.parse_args()

    args.outdir.mkdir(parents=True, exist_ok=True)
    content_id = str(uuid.uuid4()).upper()
    size = (args.width - args.width % 2, args.height - args.height % 2)

    jpeg_out = args.outdir / f"{args.basename}.JPG"
    mov_out = args.outdir / f"{args.basename}.MOV"

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        raw_mov = tmp_path / "raw.mov"
        make_video(args.dark, args.bright, raw_mov, size)
        shutil.copy2(raw_mov, mov_out)
        stamp_mov_content_id(mov_out, content_id)

    write_live_jpeg(args.bright, jpeg_out, content_id, size)
    verify(jpeg_out, mov_out, content_id)

    manifest = args.outdir / "README.txt"
    manifest.write_text(
        f"""Live Photo: {args.basename}
ContentIdentifier: {content_id}

Файлы (оба нужны, имена должны совпадать):
  {jpeg_out.name}  — ключевой кадр (луч включён)
  {mov_out.name}  — движение, ровно {DURATION_S:.1f} с
    0.00–{DARK_HOLD_S:.2f}s первый кадр
    {DARK_HOLD_S:.2f}–{DURATION_S:.1f}s второй кадр (жёсткая смена, без fade)

Как попасть на iPhone:
1) На Mac перетащите оба файла вместе в «Фото».
2) На iPhone: импортируйте парой через Live Photo Creator / ImgPlay / Lively.
3) Обои: Фото → Live Photo → Сделать обоями → Live вкл.

Эффект: нажали и держите — включается луч фонарика.
""",
        encoding="utf-8",
    )
    print(f"Wrote {jpeg_out}")
    print(f"Wrote {mov_out}")
    print(f"ContentIdentifier={content_id}")


if __name__ == "__main__":
    main()
