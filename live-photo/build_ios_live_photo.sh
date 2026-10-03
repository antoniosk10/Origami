#!/usr/bin/env bash
# Build an iPhone-compatible Live Photo using the proven goLive container
# transplant: HEVC + real still-image-time / live-photo-info mebx tracks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BASE_MOV="${ROOT}/ios-base/base.mov"
BASE_HEIC="${ROOT}/ios-base/base.HEIC"
DARK="${ROOT}/frame-dark.jpg"
BRIGHT="${ROOT}/frame-bright.jpg"
OUTDIR="${ROOT}/output-ios"
BASENAME="${1:-IMG_FLASH}"
EXIFTOOL="${EXIFTOOL:-/tmp/exiftool-13.25/exiftool}"

export PATH="/tmp/exiftool-13.25:/usr/local/bin:${PATH}"

for f in "$BASE_MOV" "$BASE_HEIC" "$DARK" "$BRIGHT"; do
  [[ -f "$f" ]] || { echo "missing $f"; exit 1; }
done
command -v ffmpeg >/dev/null
command -v MP4Box >/dev/null
command -v uuidgen >/dev/null
[[ -x "$EXIFTOOL" ]] || EXIFTOOL="$(command -v exiftool)"

# uuidgen-style lowercase — matches real iPhone / goLive output.
UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
mkdir -p "$OUTDIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASE_W="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$BASE_MOV" | tr -d ',')"
BASE_H="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$BASE_MOV" | tr -d ',')"
BASE_DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BASE_MOV")"
BASE_FPS="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$BASE_MOV" | awk -F/ '{print ($2? $1/$2: $1)}')"

# still-image-time presentation start from edit list of the still-image-time mebx track.
STILL_T="$(python3 - <<'PY' "$BASE_MOV"
import subprocess, sys
mov = sys.argv[1]
out = subprocess.check_output(['MP4Box', '-info', mov], stderr=subprocess.STDOUT, text=True, errors='replace')
# Find mebx track whose edit duration is between 0.2s and media duration (still marker).
still = None
lines = out.splitlines()
i = 0
while i < len(lines):
    line = lines[i]
    if 'Media Type: meta:mebx' in line:
        # look backwards for "Track has 2 edits: track duration is HH:MM:SS.mmm"
        for j in range(i, max(-1, i-12), -1):
            if 'Track has 2 edits: track duration is' in lines[j]:
                # parse 00:00:01.470
                part = lines[j].split('track duration is')[-1].strip()
                hh, mm, ss = part.split(':')
                still = int(hh)*3600 + int(mm)*60 + float(ss)
                break
    i += 1
print(f'{still:.3f}' if still is not None else '1.470')
PY
)"

echo "Base: ${BASE_W}x${BASE_H} ${BASE_DUR}s ${BASE_FPS}fps  still@${STILL_T}s"
echo "UUID: $UUID"

# Previous working cut was 0.45s; hold first frame 0.5s longer → 0.95s.
# Keep cut before still-image-time so the key photo stays on the bright frame.
CUT="$(python3 -c "c=0.45+0.5; s=float('$STILL_T'); d=float('$BASE_DUR'); print(f'{min(c, s-0.05, d-0.08):.3f}')")"
BRIGHT_DUR="$(python3 -c "print(max(0.05, float('$BASE_DUR')-float('$CUT')))")"
echo "Timing: first 0..${CUT}s → second (still-image-time@${STILL_T}s)"

# Pad portrait frames into base geometry (no stretch), hard-cut, HEVC hvc1.
VF_PAD="scale=${BASE_W}:${BASE_H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${BASE_W}:${BASE_H}:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=${BASE_FPS},format=yuv420p,setpts=PTS-STARTPTS"

ffmpeg -y \
  -loop 1 -t "$CUT" -i "$DARK" \
  -loop 1 -t "$BRIGHT_DUR" -i "$BRIGHT" \
  -filter_complex "\
[0:v]${VF_PAD}[v0];\
[1:v]${VF_PAD}[v1];\
[v0][v1]concat=n=2:v=1:a=0,trim=duration=${BASE_DUR},setpts=PTS-STARTPTS[v]" \
  -map '[v]' \
  -c:v libx265 -crf 12 -preset medium -tag:v hvc1 -pix_fmt yuv420p \
  -x265-params "level-idc=5" \
  -an -t "$BASE_DUR" \
  -map_metadata -1 -metadata creation_time="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  "$WORK/content.mov"

# goLive MAGIC: raw HEVC into real iPhone Live Photo container (keeps mebx).
MP4Box -raw 1 "$WORK/content.mov" -out "$WORK/video.h265"
MP4Box -add "$WORK/video.h265" -add "$BASE_MOV" -new "$WORK/paired.mov"

# Drop donor audio (keeps flashlight silent) — find lpcm/mp4a track id.
AUDIO_ID="$(MP4Box -info "$WORK/paired.mov" 2>&1 | awk '
  /# Track / { for(i=1;i<=NF;i++) if ($i=="ID") tid=$(i+1) }
  /Media Type: soun:/ { print tid; exit }
')"
if [[ -n "${AUDIO_ID:-}" && "${AUDIO_ID}" =~ ^[0-9]+$ ]]; then
  echo "Removing audio track ID ${AUDIO_ID}"
  MP4Box -rem "$AUDIO_ID" "$WORK/paired.mov" -out "$WORK/paired_silent.mov"
  mv "$WORK/paired_silent.mov" "$WORK/paired.mov"
else
  echo "No removable audio track (id='${AUDIO_ID:-none}')"
fi

OUT_MOV="$OUTDIR/${BASENAME}.mov"
OUT_HEIC="$OUTDIR/${BASENAME}.HEIC"
OUT_JPG="$OUTDIR/${BASENAME}.JPG"
cp "$WORK/paired.mov" "$OUT_MOV"
cp "$OUT_MOV" "$OUTDIR/${BASENAME}.MOV"

# Key still = frame at still-image-time (bright half after longer dark hold).
ffmpeg -y -ss "$STILL_T" -i "$WORK/content.mov" -frames:v 1 -update 1 -compression_level 0 "$WORK/still.png"
"$EXIFTOOL" -icc_profile -b "$BASE_HEIC" > "$WORK/base.icc" || true
PROFILE_OPTION=()
if [[ -s "$WORK/base.icc" ]]; then
  PROFILE_OPTION=(-profile "$WORK/base.icc")
fi

if magick "$WORK/still.png" -depth 10 -quality 100 -define heic:lossless=true \
    "${PROFILE_OPTION[@]}" "$OUT_HEIC" 2>/dev/null; then
  :
elif command -v heif-enc >/dev/null; then
  heif-enc -q 95 -o "$OUT_HEIC" "$WORK/still.png"
else
  echo "no HEIC encoder"; exit 1
fi

ffmpeg -y -ss "$STILL_T" -i "$WORK/content.mov" -frames:v 1 -update 1 -q:v 2 "$OUT_JPG"

STAMP="2025:03:08 08:42:07"

"$EXIFTOOL" -overwrite_original -m -F -ignoreMinorErrors -ee3 -TagsFromFile "$BASE_MOV" -all:all "$OUT_MOV" || true
"$EXIFTOOL" -overwrite_original -m -F -ignoreMinorErrors -ee3 -TagsFromFile "$BASE_HEIC" -all:all "$OUT_HEIC" || true

"$EXIFTOOL" -overwrite_original -m -F -api QuickTimeUTC \
  -QuickTime:CreateDate="$STAMP" \
  -QuickTime:ModifyDate="$STAMP" \
  -QuickTime:TrackCreateDate="$STAMP" \
  -QuickTime:TrackModifyDate="$STAMP" \
  -QuickTime:MediaCreateDate="$STAMP" \
  -QuickTime:MediaModifyDate="$STAMP" \
  -SubSecCreateDate="${STAMP}.000" \
  -QuickTime:ContentIdentifier="$UUID" \
  -Keys:ContentIdentifier="$UUID" \
  -Apple:ContentIdentifier="$UUID" \
  -LivePhotoAuto=1 \
  -Keys:LivePhotoAuto=1 \
  -LivePhotoVitalityScore=1 \
  -Keys:LivePhotoVitalityScore=1 \
  -LivePhotoVitalityScoringVersion=4 \
  -Keys:LivePhotoVitalityScoringVersion=4 \
  "$OUT_MOV"

"$EXIFTOOL" -overwrite_original -m -F -api QuickTimeUTC \
  -QuickTime:CreateDate="$STAMP" \
  -QuickTime:ModifyDate="$STAMP" \
  -SubSecCreateDate="${STAMP}.000" \
  -Apple:ContentIdentifier="$UUID" \
  -ContentIdentifier="$UUID" \
  "$OUT_HEIC"

# JPG: copy MakerNotes from already-stamped HEIC (direct Apple:ContentIdentifier write is a no-op).
"$EXIFTOOL" -overwrite_original -m -F -ignoreMinorErrors \
  -TagsFromFile "$OUT_HEIC" -MakerNotes -Apple:all \
  "$OUT_JPG" || true

cp "$OUT_MOV" "$OUTDIR/${BASENAME}.MOV"

PVT="$OUTDIR/${BASENAME}.pvt"
rm -rf "$PVT"
mkdir -p "$PVT"
cp "$OUT_HEIC" "$OUT_MOV" "$PVT/"
cat > "$PVT/metadata.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>PFVideoComplementMetadataVersionKey</key>
    <string>1</string>
  </dict>
</plist>
PLIST

PAIR_HEIC="$OUTDIR/${BASENAME}_HEIC_MOV"
PAIR_JPG="$OUTDIR/${BASENAME}_JPG_MOV"
rm -rf "$PAIR_HEIC" "$PAIR_JPG"
mkdir -p "$PAIR_HEIC" "$PAIR_JPG"
cp "$OUT_HEIC" "$OUT_MOV" "$PAIR_HEIC/"
cp "$OUT_JPG" "$OUT_MOV" "$PAIR_JPG/"

cat > "$OUTDIR/README.txt" <<EOF
iPhone Live Photo: ${BASENAME}
ContentIdentifier: ${UUID}

ЧТО СКАЧАТЬ
  ${BASENAME}_iOS.pvt.zip / ${BASENAME}_JPG_MOV.zip / ${BASENAME}_HEIC_MOV.zip

КАК ИМПОРТИРОВАТЬ
1) Удалите старый ${BASENAME} из Фото + «Недавно удалённые».
2) Mac: Фото → Файл → Импортировать… → оба файла (JPG+mov или HEIC+mov) → iCloud.
3) Или AirDrop всей папки ${BASENAME}.pvt.

Тайминг (~${BASE_DUR} с):
  0.00–${CUT}s первый кадр (на 0.5с дольше, чем раньше)
  ${CUT}s жёсткая смена → второй кадр
  ключ (still-image-time) ~${STILL_T}s — кадр видео в этот момент
EOF

cd "$ROOT"
rm -f "${BASENAME}_iOS.pvt.zip" "${BASENAME}_iOS_LivePhoto.zip" \
      "${BASENAME}_HEIC_MOV.zip" "${BASENAME}_JPG_MOV.zip"
(
  cd "$OUTDIR"
  zip -r -X "$ROOT/${BASENAME}_iOS.pvt.zip" "${BASENAME}.pvt"
  zip -j -X "$ROOT/${BASENAME}_iOS_LivePhoto.zip" "${BASENAME}.HEIC" "${BASENAME}.mov" README.txt
  zip -j -X "$ROOT/${BASENAME}_HEIC_MOV.zip" "${BASENAME}_HEIC_MOV"/*
  zip -j -X "$ROOT/${BASENAME}_JPG_MOV.zip" "${BASENAME}_JPG_MOV"/*
)

echo "Wrote $OUT_HEIC"
echo "Wrote $OUT_JPG"
echo "Wrote $OUT_MOV"
echo "Wrote $PVT"
echo "UUID=$UUID CUT=$CUT STILL=$STILL_T"

if [[ -f /tmp/livephoto-check/bin/cli.js ]]; then
  node /tmp/livephoto-check/bin/cli.js "$OUT_MOV" "$OUT_HEIC" || true
fi
