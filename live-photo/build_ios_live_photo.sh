#!/usr/bin/env bash
# Build an iPhone-compatible Live Photo using a real iPhone Live Photo
# container (goLive technique): HEVC video + transplanted mebx tracks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BASE_MOV="${ROOT}/ios-base/base.mov"
BASE_HEIC="${ROOT}/ios-base/base.HEIC"
DARK="${ROOT}/frame-dark.jpg"
BRIGHT="${ROOT}/frame-bright.jpg"
OUTDIR="${ROOT}/output-ios"
BASENAME="${1:-IMG_FLASH}"
EXIFTOOL="${EXIFTOOL:-/tmp/exiftool-13.25/exiftool}"

for f in "$BASE_MOV" "$BASE_HEIC" "$DARK" "$BRIGHT"; do
  [[ -f "$f" ]] || { echo "missing $f"; exit 1; }
done
command -v ffmpeg >/dev/null
command -v MP4Box >/dev/null
command -v magick >/dev/null || command -v convert >/dev/null
[[ -x "$EXIFTOOL" ]] || EXIFTOOL="$(command -v exiftool)"

UUID="$(python3 -c 'import uuid; print(str(uuid.uuid4()).upper())')"
mkdir -p "$OUTDIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASE_W="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$BASE_MOV" | tr -d ',')"
BASE_H="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$BASE_MOV" | tr -d ',')"
BASE_DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BASE_MOV")"
BASE_FPS="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$BASE_MOV" | awk -F/ '{print ($2? $1/$2: $1)}')"

echo "Base: ${BASE_W}x${BASE_H} ${BASE_DUR}s ${BASE_FPS}fps"
echo "UUID: $UUID"

# still-image-time in base is ~0.5s → keep first frame before that, then hard-cut to bright.
CUT=0.45
# Build hard-cut HEVC clip matching base geometry/duration (no audio; base has none).
ffmpeg -y \
  -loop 1 -t "$CUT" -i "$DARK" \
  -loop 1 -t "$(python3 -c "print(max(0.05, float('$BASE_DUR')-$CUT))")" -i "$BRIGHT" \
  -filter_complex "\
[0:v]scale=${BASE_W}:${BASE_H}:flags=lanczos,setsar=1,fps=${BASE_FPS},format=yuv420p,setpts=PTS-STARTPTS[v0];\
[1:v]scale=${BASE_W}:${BASE_H}:flags=lanczos,setsar=1,fps=${BASE_FPS},format=yuv420p,setpts=PTS-STARTPTS[v1];\
[v0][v1]concat=n=2:v=1:a=0,trim=duration=${BASE_DUR},setpts=PTS-STARTPTS[v]" \
  -map '[v]' \
  -c:v libx265 -crf 18 -preset medium -tag:v hvc1 -pix_fmt yuv420p \
  -an -t "$BASE_DUR" \
  "$WORK/content.mov"

# Transplant video bitstream into the real iPhone Live Photo container (keeps mebx tracks).
MP4Box -raw 1 "$WORK/content.mov" -out "$WORK/video.h265"
MP4Box -add "$WORK/video.h265" -add "$BASE_MOV" -new "$WORK/paired.mov"

OUT_MOV="$OUTDIR/${BASENAME}.MOV"
OUT_HEIC="$OUTDIR/${BASENAME}.HEIC"
cp "$WORK/paired.mov" "$OUT_MOV"

# Key still = bright frame as HEIC (matches still-image-time ~0.5s which is in bright half).
convert "$BRIGHT" -resize "${BASE_W}x${BASE_H}!" "$WORK/still.png"
heif-enc -q 90 -o "$OUT_HEIC" "$WORK/still.png"

# Inherit Apple MakerNotes / container tags from the real Live Photo, then set shared UUID.
"$EXIFTOOL" -overwrite_original -m -F -ignoreMinorErrors -ee3 -TagsFromFile "$BASE_MOV" -all:all "$OUT_MOV" || true
"$EXIFTOOL" -overwrite_original -m -F -ignoreMinorErrors -ee3 -TagsFromFile "$BASE_HEIC" -all:all "$OUT_HEIC" || true

"$EXIFTOOL" -overwrite_original -m -F \
  -QuickTime:ContentIdentifier="$UUID" \
  -Keys:ContentIdentifier="$UUID" \
  -Keys:LivePhotoAuto=1 \
  -Keys:LivePhotoVitalityScore=1.0 \
  -Keys:LivePhotoVitalityScoringVersion=4 \
  "$OUT_MOV"

"$EXIFTOOL" -overwrite_original -m -F \
  -Apple:ContentIdentifier="$UUID" \
  -ContentIdentifier="$UUID" \
  "$OUT_HEIC"

# .pvt package for AirDrop
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

cat > "$OUTDIR/README.txt" <<EOF
iPhone Live Photo: ${BASENAME}
ContentIdentifier: ${UUID}

Files:
  ${BASENAME}.HEIC  — key photo
  ${BASENAME}.MOV   — paired video (HEVC + real iPhone mebx tracks)
  ${BASENAME}.pvt/  — AirDrop this folder

Import on iPhone:
1) Best: on Mac open Photos and drop HEIC+MOV (or .pvt), wait for iCloud.
2) Or AirDrop the whole .pvt folder to iPhone → Save to Photos.

Timing inside ~${BASE_DUR}s iPhone Live Photo window:
  0.00–${CUT}s first frame
  ${CUT}s hard cut to second frame (still/key ~0.5s is the bright frame)
EOF

echo "Wrote $OUT_HEIC"
echo "Wrote $OUT_MOV"
echo "Wrote $PVT"
echo "UUID=$UUID"
