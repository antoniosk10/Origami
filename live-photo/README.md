# Live Photo для iPhone — фонарик

Из двух кадров собран Apple Live Photo: 1.5 с первый кадр → сразу второй (без fade).

## Почему на Mac работает, а на iPhone нет

Mac Photos часто принимает пару только по общему `ContentIdentifier`.  
iPhone строже: нужен ещё трек `still-image-time` (mebx) в MOV и правильный способ импорта.

В этой сборке есть:
- общий `ContentIdentifier` в JPG + MOV
- `Keys:LivePhotoAuto` / `LivePhotoVitalityScore`
- mebx-трек `com.apple.quicktime.still-image-time` на 1.5 с (начало второго кадра)
- пакет `.pvt` для AirDrop

## Готовые файлы

| Файл | Назначение |
|------|------------|
| `output/IMG_FLASH.JPG` | ключевой кадр (луч) |
| `output/IMG_FLASH.MOV` | видео 3.0 с + still-image-time |
| `output/IMG_FLASH.pvt/` | пакет JPG+MOV+metadata.plist |
| `IMG_FLASH.pvt.zip` | тот же `.pvt` архивом |
| `IMG_FLASH_LivePhoto.zip` | JPG+MOV |

## Как поставить на iPhone

**Самый надёжный способ**
1. На Mac перетащите `IMG_FLASH.JPG` + `IMG_FLASH.MOV` (или папку `.pvt`) в «Фото».
2. Дождитесь синхронизации iCloud → Live Photo появится на iPhone.

**AirDrop**
1. Скачайте `IMG_FLASH.pvt.zip`, распакуйте в `IMG_FLASH.pvt`.
2. AirDrop **всю папку** `.pvt` на iPhone (не один MOV).
3. На iPhone откройте и сохраните в Фото.

**Обои:** Фото → Live Photo → «Сделать обоями» → Live вкл.

## Пересобрать

```bash
python3 live-photo/make_live_photo.py \
  --dark live-photo/frame-dark.jpg \
  --bright live-photo/frame-bright.jpg \
  --outdir live-photo/output \
  --basename IMG_FLASH
```

Нужны: `ffmpeg`, `python3` + `Pillow`/`piexif`, `exiftool`.
