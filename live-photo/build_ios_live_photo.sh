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

echo "Base: ${BASE_W}x${BASE_H} ${BASE_DUR}s ${BASE_FPS}fps"
echo "UUID: $UUID"

CUT=0.45
BRIGHT_DUR="$(python3 -c "print(max(0.05, float('$BASE_DUR')-$CUT))")"

# Hard-cut flashlight clip: dark → bright, Main10 HEVC hvc1 (goLive-compatible).
ffmpeg -y \
  -loop 1 -t "$CUT" -i "$DARK" \
  -loop 1 -t "$BRIGHT_DUR" -i "$BRIGHT" \
  -filter_complex "\
[0:v]scale=${BASE_W}:${BASE_H}:flags=lanczos,setsar=1,fps=${BASE_FPS},format=yuv420p10le,setpts=PTS-STARTPTS[v0];\
[1:v]scale=${BASE_W}:${BASE_H}:flags=lanczos,setsar=1,fps=${BASE_FPS},format=yuv420p10le,setpts=PTS-STARTPTS[v1];\
[v0][v1]concat=n=2:v=1:a=0,trim=duration=${BASE_DUR},setpts=PTS-STARTPTS[v]" \
  -map '[v]' \
  -c:v libx265 -crf 0 -preset medium -tag:v hvc1 -pix_fmt yuv420p10le \
  -x265-params "level-idc=4.1" \
  -an -t "$BASE_DUR" \
  -map_metadata -1 -metadata creation_time="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  "$WORK/content.mov"

# goLive MAGIC: raw HEVC into real iPhone Live Photo container (keeps mebx).
# Track order becomes: 1=our video, 2=donor video, 3/4=mebx. iOS uses track 1.
MP4Box -raw 1 "$WORK/content.mov" -out "$WORK/video.h265"
MP4Box -add "$WORK/video.h265" -add "$BASE_MOV" -new "$WORK/paired.mov"

OUT_MOV="$OUTDIR/${BASENAME}.mov"
OUT_HEIC="$OUTDIR/${BASENAME}.HEIC"
OUT_JPG="$OUTDIR/${BASENAME}.JPG"
cp "$WORK/paired.mov" "$OUT_MOV"
# Uppercase alias for importers that expect .MOV
cp "$OUT_MOV" "$OUTDIR/${BASENAME}.MOV"

# Still at still-image-time (~0.50s) = bright frame after hard cut.
ffmpeg -y -ss 0.50 -i "$WORK/content.mov" -frames:v 1 -update 1 -compression_level 0 "$WORK/still.png"
"$EXIFTOOL" -icc_profile -b "$BASE_HEIC" > "$WORK/base.icc" || true
PROFILE_OPTION=()
if [[ -s "$WORK/base.icc" ]]; then
  PROFILE_OPTION=(-profile "$WORK/base.icc")
fi

# Prefer ImageMagick HEIC like goLive; fall back to heif-enc.
if magick "$WORK/still.png" -depth 10 -quality 100 -define heic:lossless=true \
    "${PROFILE_OPTION[@]}" "$OUT_HEIC" 2>/dev/null; then
  :
elif command -v heif-enc >/dev/null; then
  heif-enc -q 95 -o "$OUT_HEIC" "$WORK/still.png"
else
  echo "no HEIC encoder"; exit 1
fi

# JPG still — some Photos import paths pair JPG+MOV more reliably than HEIC.
ffmpeg -y -ss 0.50 -i "$WORK/content.mov" -frames:v 1 -update 1 -q:v 2 "$OUT_JPG"

STAMP="2025:03:08 08:42:07"

# Inherit donor Apple tags, then stamp shared UUID (goLive tag set).
"$EXIFTOOL" -overwrite_original -m -F -ignoreMinorErrors -ee3 -TagsFromFile "$BASE_MOV" -all:all "$OUT_MOV" || true
"$EXIFTOOL" -overwrite_original -m -F -ignoreMinorErrors -ee3 -TagsFromFile "$BASE_HEIC" -all:all "$OUT_HEIC" || true
# JPG gets MakerNotes block from donor HEIC / image so Apple:ContentIdentifier can live there.
"$EXIFTOOL" -overwrite_original -m -F -ignoreMinorErrors -TagsFromFile "$BASE_HEIC" -Apple:all -MakerNotes "$OUT_JPG" || true

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

"$EXIFTOOL" -overwrite_original -m -F \
  -Apple:ContentIdentifier="$UUID" \
  -ContentIdentifier="$UUID" \
  "$OUT_JPG"

cp "$OUT_MOV" "$OUTDIR/${BASENAME}.MOV"

# .pvt package: HEIC + mov only (no duplicate extensions).
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

# Flat pair folders for easy AirDrop / Photos Import
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
  ${BASENAME}_iOS.pvt.zip     → распаковать → папка ${BASENAME}.pvt
  или ${BASENAME}_HEIC_MOV.zip / ${BASENAME}_JPG_MOV.zip

КАК ИМПОРТИРОВАТЬ (важно!)
1) На Mac: Фото → Файл → Импортировать… → выбрать ОБА файла (HEIC+mov или JPG+mov).
   Дождаться синхронизации iCloud Photos на iPhone.
2) AirDrop: отправить папку ${BASENAME}.pvt целиком (не zip и не один HEIC).
3) Перед повторным импортом удалите старый ${BASENAME} из Фото + «Недавно удалённые».
4) Нельзя: открыть только HEIC в «Файлы» → «Сохранить изображение» — Live пропадает.

Тайминг (~${BASE_DUR} с):
  0.00–${CUT}s тёмный кадр
  ${CUT}s жёсткая смена → луч (ключ ~0.50s)
EOF

# Zips at live-photo root
cd "$ROOT"
rm -f "${BASENAME}_iOS.pvt.zip" "${BASENAME}_iOS_LivePhoto.zip" \
      "${BASENAME}_HEIC_MOV.zip" "${BASENAME}_JPG_MOV.zip"
(
  cd "$OUTDIR"
  # zip folder so extract yields IMG_FLASH.pvt/
  zip -r -X "$ROOT/${BASENAME}_iOS.pvt.zip" "${BASENAME}.pvt"
  zip -j -X "$ROOT/${BASENAME}_iOS_LivePhoto.zip" "${BASENAME}.HEIC" "${BASENAME}.mov" README.txt
  zip -j -X "$ROOT/${BASENAME}_HEIC_MOV.zip" "${BASENAME}_HEIC_MOV"/*
  zip -j -X "$ROOT/${BASENAME}_JPG_MOV.zip" "${BASENAME}_JPG_MOV"/*
)

echo "Wrote $OUT_HEIC"
echo "Wrote $OUT_JPG"
echo "Wrote $OUT_MOV"
echo "Wrote $PVT"
echo "UUID=$UUID"

if [[ -f /tmp/livephoto-check/bin/cli.js ]]; then
  node /tmp/livephoto-check/bin/cli.js "$OUT_MOV" "$OUT_HEIC" || true
fi
