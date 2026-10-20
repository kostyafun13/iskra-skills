"""Расшифровка голоса для ИИ: голосовые, записи созвонов, видео → текст.

Сервис по умолчанию — Яндекс SpeechKit (оплата российской картой). Запасной — OpenAI (нужна зарубежная карта).
Ключи — в .env рядом со скриптом. Нужны Python 3.9+, certifi и ffmpeg.
Уже расшифрованное второй раз не отправляется: рядом с файлом лежит .txt — пропускаем.
"""
import argparse
import glob
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
YANDEX = "https://stt.api.cloud.yandex.net/speech/v1/stt:recognize"
OPENAI = "https://api.openai.com/v1/audio/transcriptions"
AUDIO = {".ogg", ".oga", ".opus", ".mp3", ".m4a", ".wav", ".aac", ".flac", ".mp4", ".mov", ".webm", ".mkv", ".aiff"}
try:  # Python с python.org на Mac не видит системные сертификаты — берём их из certifi
    import certifi
    CTX = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    CTX = ssl.create_default_context()


def env():
    f = ROOT / ".env"
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.split("#")[0].strip().strip('"'))
    prov = os.environ.get("STT_PROVIDER", "yandex")
    key = {"yandex": "YANDEX_API_KEY", "openai": "OPENAI_API_KEY"}.get(prov)
    if not key:
        raise SystemExit("STT_PROVIDER — yandex или openai.")
    if not os.environ.get(key):
        raise SystemExit(f"Заполните {key} в .env рядом со скриптом.")
    if not shutil.which("ffmpeg"):
        raise SystemExit("Нужен ffmpeg: Mac — brew install ffmpeg, Windows — winget install ffmpeg.")
    return prov


def narezat(src, papka, sek, kodek):
    """Аудиодорожка → куски по sek секунд. -reset_timestamps 1 обязателен: иначе Яндекс видит
    сквозное время больше 30 секунд и отбивает кусок."""
    ext = "ogg" if kodek == "libopus" else "mp3"
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vn", "-map", "0:a:0", "-ac", "1", "-ar", "16000",
           "-c:a", kodek, "-b:a", "32k", "-f", "segment", "-segment_time", str(sek), "-reset_timestamps", "1",
           os.path.join(papka, f"part_%04d.{ext}")]
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode:
        raise SystemExit("ffmpeg не прочитал файл: " + r.stderr.decode("utf-8", "replace")[-300:])
    return sorted(glob.glob(os.path.join(papka, f"part_*.{ext}")))


def yandex(kusok):
    q = {"lang": os.environ.get("STT_LANG", "ru-RU"), "format": "oggopus"}
    if os.environ.get("YANDEX_FOLDER_ID"):
        q["folderId"] = os.environ["YANDEX_FOLDER_ID"]
    req = urllib.request.Request(f"{YANDEX}?{urllib.parse.urlencode(q)}", data=Path(kusok).read_bytes(),
                                 headers={"Authorization": f"Api-Key {os.environ['YANDEX_API_KEY']}"})
    return json.load(urllib.request.urlopen(req, timeout=120, context=CTX)).get("result", "")


def openai(kusok):
    granica = uuid.uuid4().hex
    telo = (f"--{granica}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n"
            f"{os.environ.get('OPENAI_STT_MODEL', 'gpt-4o-mini-transcribe')}\r\n"
            f"--{granica}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.mp3\"\r\n"
            f"Content-Type: audio/mpeg\r\n\r\n").encode() + Path(kusok).read_bytes() + f"\r\n--{granica}--\r\n".encode()
    req = urllib.request.Request(OPENAI, data=telo, headers={
        "Authorization": f"Bearer {os.environ['OPENAI_API_KEY']}", "Content-Type": f"multipart/form-data; boundary={granica}"})
    return json.load(urllib.request.urlopen(req, timeout=600, context=CTX)).get("text", "")


def rasshifrovat(src, prov):
    """Яндекс: куски по 25 секунд, синхронный запрос (лимит 30 секунд). OpenAI: куски по 10 минут."""
    with tempfile.TemporaryDirectory() as t:
        if prov == "yandex":
            kuski = narezat(src, t, 25, "libopus")
            return " ".join(x for x in (yandex(k).strip() for k in kuski) if x), len(kuski) * 25
        kuski = narezat(src, t, 600, "libmp3lame")
        return " ".join(x for x in (openai(k).strip() for k in kuski) if x), len(kuski) * 600


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("status", help="Проверить ключ и ffmpeg на 1 секунде тишины")
    f = sub.add_parser("file", help="Один файл → текст")
    f.add_argument("--in", dest="src", required=True)
    f.add_argument("--out", help="Куда положить .txt (по умолчанию рядом с файлом)")
    d = sub.add_parser("folder", help="Все аудио и видео папки → .txt рядом, уже готовое пропускаем")
    d.add_argument("--in", dest="src", required=True)
    a = p.parse_args()
    prov = env()
    if a.command == "status":
        with tempfile.TemporaryDirectory() as t:
            tishina = os.path.join(t, "tishina.wav")
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                            "-t", "1", tishina], check=True)
            rasshifrovat(tishina, prov)
        print(f"Расшифровка работает: сервис {prov}, ffmpeg найден.")
        return
    faily = [Path(a.src)] if a.command == "file" else sorted(x for x in Path(a.src).iterdir() if x.suffix.lower() in AUDIO)
    for src in faily:
        out = Path(a.out) if a.command == "file" and a.out else src.with_suffix(".txt")
        if out.exists():
            print("уже есть, пропускаю:", out.name)
            continue
        tekst, sek = rasshifrovat(src, prov)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(tekst + "\n", encoding="utf-8")
        print(f"{src.name} → {out.name} · до {sek // 60} мин {sek % 60} с по счёту сервиса")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        raise SystemExit(f"Сервис ответил {e.code}: {e.read().decode('utf-8', 'replace')[:300]}")
    except urllib.error.URLError as e:
        if "CERTIFICATE" in str(e):
            raise SystemExit("Python не видит сертификаты. Выполните: python3 -m pip install certifi — и повторите.")
        raise SystemExit(f"Нет связи с сервисом: {e.reason}")
