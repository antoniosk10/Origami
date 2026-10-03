# Live Photo для iPhone — фонарик

Пересобранная iOS-версия (как [goLive](https://github.com/code-path/goLive)): HEVC, `still-image-time`, `live-photo-info`, vitality, **lowercase UUID**.

Все проверки `livephoto-check` пройдены.

## Скачать

| Файл | Назначение |
|------|------------|
| `IMG_FLASH_iOS.pvt.zip` | **лучше всего** → распаковать → AirDrop папку `.pvt` |
| `IMG_FLASH_HEIC_MOV.zip` | пара HEIC + mov |
| `IMG_FLASH_JPG_MOV.zip` | пара JPG + mov (часто проще для «Фото» на Mac) |
| `IMG_FLASH_iOS_LivePhoto.zip` | HEIC + mov + README |

## Импорт (если «не работает» — почти всегда из‑за способа)

1. Удалите старый `IMG_FLASH` из «Фото» **и** из «Недавно удалённые».
2. **Надёжный путь:** на Mac → «Фото» → **Файл → Импортировать…** → выберите **оба** файла сразу (HEIC+mov или JPG+mov) → дождитесь iCloud на iPhone.
3. **AirDrop:** распакуйте zip, отправьте **всю папку** `IMG_FLASH.pvt` (не zip и не один HEIC).
4. Не сохраняйте только HEIC/JPG из «Файлы» — Live-пара пропадает.

## Тайминг (~1.05 с, окно Live Photo iPhone)

- ~0.45 с — тёмный кадр  
- жёсткая смена — луч (ключ ~0.50 с)

## Пересобрать

```bash
./live-photo/build_ios_live_photo.sh IMG_FLASH
```

Нужны: ffmpeg (libx265), MP4Box, ImageMagick/`heif-enc`, exiftool, uuidgen.  
Шаблон: `ios-base/` (из goLive, MIT).
