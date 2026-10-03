# Live Photo для iPhone — фонарик

iOS-сборка (как goLive): HEVC + `still-image-time` / `live-photo-info` / vitality.
Первый кадр держится **~0.95 с** (на 0.5 с дольше, чем в предыдущей рабочей версии).

## Скачать

| Файл | Назначение |
|------|------------|
| `IMG_FLASH_JPG_MOV.zip` | **удобно** → Mac «Фото» → Импортировать JPG+mov |
| `IMG_FLASH_iOS.pvt.zip` | AirDrop папки `.pvt` |
| `IMG_FLASH_HEIC_MOV.zip` | HEIC + mov |

## Импорт

1. Удалите старый `IMG_FLASH` из «Фото» и «Недавно удалённые».
2. Mac → «Фото» → **Файл → Импортировать…** → оба файла → iCloud на iPhone.
3. Или AirDrop всей папки `IMG_FLASH.pvt`.

## Тайминг (~3 с)

- **0.00–0.95 с** — первый кадр  
- **0.95 с** — жёсткая смена → второй кадр (ключ ~1.47 с)

## Пересобрать

```bash
./live-photo/build_ios_live_photo.sh IMG_FLASH
```
