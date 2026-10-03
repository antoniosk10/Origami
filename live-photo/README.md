# Live Photo для iPhone — фонарик

## Важно: версия для iPhone

Предыдущие JPG+MOV работали на Mac, но iPhone отклонял их.
Нужны: **HEVC**, настоящие треки `still-image-time` + `live-photo-info`, vitality metadata.

Сейчас есть iOS-сборка (все проверки `livephoto-check` пройдены):

| Файл | Назначение |
|------|------------|
| `IMG_FLASH_iOS.pvt.zip` | **скачайте это** → распакуйте → AirDrop папку `.pvt` |
| `IMG_FLASH_iOS_LivePhoto.zip` | HEIC + MOV |
| `output-ios/IMG_FLASH.HEIC` + `.MOV` | пара файлов |

### Импорт на iPhone

1. **Надёжно:** на Mac перетащите HEIC+MOV (или `.pvt`) в «Фото» → дождитесь iCloud.
2. **AirDrop:** распакуйте `IMG_FLASH_iOS.pvt.zip`, отправьте **всю папку** `IMG_FLASH.pvt` на iPhone → сохранить в Фото.

Тайминг внутри формата iPhone (~1.05 с):
- ~0.45 с — первый кадр
- жёсткая смена — второй кадр (ключ на ~0.5 с)

### Пересобрать iOS-версию

```bash
./live-photo/build_ios_live_photo.sh IMG_FLASH
```

Нужны: ffmpeg (libx265), MP4Box, heif-enc (libheif-plugin-x265), exiftool, ImageMagick `convert`.
Шаблон контейнера: `ios-base/` (из [goLive](https://github.com/code-path/goLive), MIT).
