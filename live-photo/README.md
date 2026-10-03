# Live Photo для iPhone — фонарик

Из двух кадров собран Apple Live Photo: при нажатии луч фонарика включается.

## Готовые файлы

В папке [`output/`](output/):

| Файл | Назначение |
|------|------------|
| `IMG_FLASH.JPG` | ключевой кадр (луч включён) |
| `IMG_FLASH.MOV` | 2.0 с: 1.5 с первый кадр → жёсткая смена → второй кадр |
| `README.txt` | краткая инструкция |

Оба файла связаны одним `ContentIdentifier` (Apple MakerNote + QuickTime metadata).

Архив: артефакт `IMG_FLASH_LivePhoto.zip`.

## Как поставить на iPhone

1. **Через Mac (самый надёжный способ)**  
   Перетащите `IMG_FLASH.JPG` и `IMG_FLASH.MOV` вместе в приложение «Фото». Они склеятся в одно Live Photo и уедут на iPhone через iCloud.

2. **Прямо на iPhone**  
   Скопируйте оба файла в «Файлы», затем импортируйте парой через приложение вроде Live Photo Creator / ImgPlay / Lively.

3. **Обои**  
   Фото → Live Photo → «Поделиться» → «Сделать обоями» → включите Live.

## Пересобрать

```bash
python3 live-photo/make_live_photo.py \
  --dark live-photo/frame-dark.jpg \
  --bright live-photo/frame-bright.jpg \
  --outdir live-photo/output \
  --basename IMG_FLASH
```

Нужны: `ffmpeg`, `python3` + `Pillow`/`piexif`, `exiftool`.
