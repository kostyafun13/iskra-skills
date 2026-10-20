"""Расшифровка голоса для ИИ: голосовые, записи созвонов, видео → текст.

Сервис по умолчанию — Яндекс SpeechKit (оплата российской картой). Запасной — OpenAI (нужна зарубежная карта).
Ключи — в .env рядом со скриптом. Нужны Python 3.9+, certifi и ffmpeg.
Уже расшифрованное второй раз не отправляется: рядом с файлом лежит .txt — пропускаем.
Созвон из Zoom — режим sozvon: кто говорил берём из бесплатной расшифровки Zoom, а в сервис отправляем
только короткие куски с конкретикой (имена, компании, цифры). Весь звук остаётся на компьютере.
"""
import argparse
import glob
import json
import math
import os
import re
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


def vtt(path):
    """Расшифровка Zoom → реплики: номер, начало, конец (секунды), кто, текст."""
    def sek(t):
        h, m, x = t.replace(",", ".").split(":")
        return int(h) * 3600 + int(m) * 60 + float(x)
    cues = []
    for blok in re.split(r"\n\s*\n", Path(path).read_text(encoding="utf-8").replace("\r", "")):
        stroki = [x for x in blok.strip().splitlines() if x.strip()]
        i = next((k for k, x in enumerate(stroki) if "-->" in x), None)
        if i is None:
            continue
        a, b = (x.strip().split()[0] for x in stroki[i].split("-->"))
        tekst = " ".join(stroki[i + 1:]).strip()
        m = re.match(r"^([^:]{1,60}):\s+(.*)$", tekst)
        kto, tekst = (m.group(1).strip(), m.group(2)) if m else ((cues[-1]["kto"] if cues else ""), tekst)
        cues.append({"n": len(cues) + 1, "a": sek(a), "b": sek(b), "kto": kto, "zoom": tekst})
    if not cues:
        raise SystemExit("В файле нет реплик. Нужна расшифровка Zoom в формате .vtt (скил podklyuchit-zoom).")
    return cues


KONKRETIKA = re.compile(r"\d|[A-Za-z]{2,}|₽|\$|%|руб|тысяч|миллион|млн|млрд|процент|компани|клиент|договор|оффер|интро|"
                        r"познаком|бюджет|выручк|оборот|цен[аеуы]\b|стоит|срок", re.I)


def konkretika(tekst):
    """Запасной автоподбор, если ИИ не выбрал куски сам: цифры, латиница, суммы, проценты, деловые слова.
    Имён он не видит: русская расшифровка Zoom пишет их строчными, а заглавные ставит где попало
    (проверено на живом созвоне 20.10.2026 — правило «заглавная буква» выбрало 54 реплики из 93 впустую)."""
    return bool(KONKRETIKA.search(tekst))


def nomera(spisok):
    """«12, 15-18» → {12, 15, 16, 17, 18}."""
    out = set()
    for x in re.findall(r"\d+(?:\s*-\s*\d+)?", spisok):
        a, _, b = x.replace(" ", "").partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out


def gruppy(cues, vybrano, pad):
    """Подряд идущие выбранные реплики одного человека — одним куском до 25 секунд:
    сервис считает каждый запрос от 15 секунд, мелкие куски по отдельности дороже."""
    out = []
    for c in cues:
        if c["n"] not in vybrano:
            continue
        g = out[-1] if out else None
        if g and g["kto"] == c["kto"] and g["ns"][-1] == c["n"] - 1 and c["b"] + pad - g["a"] <= 25:
            g["ns"].append(c["n"]); g["b"] = c["b"] + pad
        else:
            out.append({"ns": [c["n"]], "kto": c["kto"], "a": max(0.0, c["a"] - pad), "b": c["b"] + pad})
    for g in out:  # одна реплика длиннее 25 секунд — режем на части
        g["chasti"] = [(g["a"] + k * 25, min(g["b"], g["a"] + (k + 1) * 25)) for k in range(math.ceil((g["b"] - g["a"]) / 25))]
    return out


def tishina(frag):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", frag, "-af", "volumedetect", "-f", "null", "-"], capture_output=True)
    m = re.search(r"mean_volume:\s*(-?[\d.]+) dB", r.stderr.decode("utf-8", "replace"))
    return bool(m) and float(m.group(1)) < -50


def sozvon(a, prov):
    cues = vtt(a.vtt)
    if a.vse:
        vybrano = {c["n"] for c in cues}
    elif a.kuski:
        vybrano = nomera(Path(a.kuski).read_text(encoding="utf-8") if Path(a.kuski).exists() else a.kuski)
    else:
        vybrano = {c["n"] for c in cues if konkretika(c["zoom"])}
    gr = gruppy(cues, vybrano, a.pad)
    sek = sum(math.ceil((y - x) / 15) * 15 for g in gr for x, y in g["chasti"])
    print(f"Реплик {len(cues)}, к сверке по звуку {len(vybrano)}, кусков {sum(len(g['chasti']) for g in gr)}, "
          f"по счёту сервиса до {sek / 60:.1f} мин.")
    if sek / 60 > a.limit_min:
        raise SystemExit(f"Больше лимита {a.limit_min} мин. Сузьте выбор (--kuski) или поднимите --limit-min после «да» владельца.")
    if a.plan:
        return
    zvuk = {}
    with tempfile.TemporaryDirectory() as t:
        wav = os.path.join(t, "full.wav")
        r = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", a.audio, "-vn", "-map", "0:a:0", "-ac", "1", "-ar", "16000", wav],
                           capture_output=True)
        if r.returncode:
            raise SystemExit("ffmpeg не прочитал звук: " + r.stderr.decode("utf-8", "replace")[-300:])
        for g in gr:
            teksty = []
            for k, (x, y) in enumerate(g["chasti"]):
                frag = os.path.join(t, f"g{g['ns'][0]}_{k}." + ("ogg" if prov == "yandex" else "mp3"))
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{x:.2f}", "-t", f"{y - x:.2f}", "-i", wav,
                                "-ac", "1", "-c:a", "libopus" if prov == "yandex" else "libmp3lame", "-b:a", "32k", frag], check=True)
                if not tishina(frag):
                    teksty.append((yandex if prov == "yandex" else openai)(frag).strip())
            zvuk[g["ns"][0]] = " ".join(x for x in teksty if x)
    vlito = {n for g in gr for n in g["ns"][1:] if zvuk.get(g["ns"][0])}
    mm = lambda x: f"{int(x // 60):02d}:{int(x % 60):02d}"
    stroki = [f"# Стенограмма — {Path(a.vtt).stem}", "",
              f"Кто говорил — из расшифровки Zoom. ✓ — место с конкретикой сверено по звуку (кусков: {len(zvuk)}, "
              f"по счёту сервиса до {sek / 60:.1f} мин). Весь звук в сервис не отправлялся.", ""]
    for c in cues:
        if c["n"] in vlito:
            continue
        t = zvuk.get(c["n"])
        stroki.append(f"[{mm(c['a'])}] {'✓ ' if t else ''}{c['kto'] or '—'}: {t or c['zoom']}")
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(stroki) + "\n", encoding="utf-8")
    sverka = [{"n": c["n"], "nachalo": mm(c["a"]), "kto": c["kto"], "zoom": c["zoom"], "zvuk": zvuk.get(c["n"])}
              for c in cues if c["n"] in zvuk]
    out.with_suffix(".sverka.json").write_text(json.dumps(sverka, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Готово: {out} · рядом {out.with_suffix('.sverka.json').name} — текст Zoom и текст по звуку для сравнения.")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("status", help="Проверить ключ и ffmpeg на 1 секунде тишины")
    f = sub.add_parser("file", help="Один файл → текст")
    f.add_argument("--in", dest="src", required=True)
    f.add_argument("--out", help="Куда положить .txt (по умолчанию рядом с файлом)")
    d = sub.add_parser("folder", help="Все аудио и видео папки → .txt рядом, уже готовое пропускаем")
    d.add_argument("--in", dest="src", required=True)
    z = sub.add_parser("sozvon", help="Созвон Zoom: кто говорил — из Zoom, конкретика — по звуку, точечно")
    z.add_argument("--vtt", required=True, help="Расшифровка Zoom .vtt")
    z.add_argument("--audio", required=True, help="Звук того же созвона .m4a")
    z.add_argument("--out", required=True, help="Стенограмма .md")
    z.add_argument("--kuski", help="Номера реплик, которые выбрал ИИ: «12, 15-18» или файл с ними")
    z.add_argument("--vse", action="store_true", help="Сверить по звуку все реплики (дороже)")
    z.add_argument("--plan", action="store_true", help="Только посчитать, сколько уйдёт в сервис")
    z.add_argument("--pad", type=float, default=0.7, help="Запас по краям куска, секунды")
    z.add_argument("--limit-min", type=float, default=15, help="Не отправлять больше N минут без «да» владельца")
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
    if a.command == "sozvon":
        sozvon(a, prov)
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
