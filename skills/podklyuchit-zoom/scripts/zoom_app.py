"""Свой Zoom для ИИ: проверка ключей, список записей и скачивание расшифровок.

Только чтение. Нужен Python 3.9+ и certifi (requirements.txt).
Ключи — в .env рядом со скриптом: ZOOM_ACCOUNT_ID, ZOOM_CLIENT_ID, ZOOM_CLIENT_SECRET, ZOOM_USER.
"""
import argparse
import base64
import datetime as dt
import json
import os
import ssl
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
API = "https://api.zoom.us/v2"
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
    need = ["ZOOM_ACCOUNT_ID", "ZOOM_CLIENT_ID", "ZOOM_CLIENT_SECRET", "ZOOM_USER"]
    if missing := [k for k in need if not os.environ.get(k)]:
        raise SystemExit("Заполните в .env рядом со скриптом: " + ", ".join(missing))


def token():
    basic = base64.b64encode(f"{os.environ['ZOOM_CLIENT_ID']}:{os.environ['ZOOM_CLIENT_SECRET']}".encode()).decode()
    q = urllib.parse.urlencode({"grant_type": "account_credentials", "account_id": os.environ["ZOOM_ACCOUNT_ID"]})
    req = urllib.request.Request(f"https://zoom.us/oauth/token?{q}", method="POST",
                                 headers={"Authorization": f"Basic {basic}"})
    return json.load(urllib.request.urlopen(req, timeout=60, context=CTX))["access_token"]


def get(tok, path, params):
    req = urllib.request.Request(f"{API}{path}?{urllib.parse.urlencode(params)}",
                                 headers={"Authorization": f"Bearer {tok}"})
    return json.load(urllib.request.urlopen(req, timeout=60, context=CTX))


def recordings(tok, days):
    """Zoom отдаёт записи окнами до 30 дней — идём окнами от сегодня назад."""
    user = urllib.parse.quote(os.environ["ZOOM_USER"])
    to, rows = dt.date.today(), []
    start = to - dt.timedelta(days=days)
    while to > start:
        frm = max(start, to - dt.timedelta(days=30))
        params = {"from": frm.isoformat(), "to": to.isoformat(), "page_size": 300}
        while True:
            j = get(tok, f"/users/{user}/recordings", params)
            for m in j.get("meetings", []):
                tr = [f for f in m.get("recording_files", []) if f.get("file_type") == "TRANSCRIPT"]
                rows.append({"uuid": m["uuid"], "topic": m.get("topic"), "start_utc": m.get("start_time"),
                             "minutes": m.get("duration"), "transcript": bool(tr),
                             "transcript_url": tr[0]["download_url"] if tr else None})
            if not j.get("next_page_token"):
                break
            params["next_page_token"] = j["next_page_token"]
        to = frm - dt.timedelta(days=1)
    return rows


def download(tok, url, out):
    # Токен — параметром ?access_token=, а не заголовком: иначе Zoom отдаёт HTML-заглушку вместо файла.
    sep = "&" if "?" in url else "?"
    text = urllib.request.urlopen(f"{url}{sep}access_token={tok}", timeout=120, context=CTX).read().decode("utf-8")
    if not text.startswith("WEBVTT"):
        raise SystemExit("Zoom вернул не расшифровку. Проверьте права приложения на записи.")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("status", help="Проверить ключи и доступ к записям")
    s = sub.add_parser("list", help="Записи за последние N дней")
    s.add_argument("--days", type=int, default=30)
    s.add_argument("--out", required=True, help="Локальный JSON")
    g = sub.add_parser("transcript", help="Скачать расшифровки из списка")
    g.add_argument("--from-list", required=True, help="JSON от команды list")
    g.add_argument("--out", required=True, help="Папка для .vtt")
    g.add_argument("--limit", type=int, default=5)
    a = p.parse_args()
    env()
    tok = token()
    if a.command == "status":
        rows = recordings(tok, 30)
        print(f"Ключи работают. Записей за 30 дней: {len(rows)}, из них с расшифровкой: {sum(r['transcript'] for r in rows)}.")
        if rows and not any(r["transcript"] for r in rows):
            print("Расшифровок нет: включите Audio transcript в настройках облачной записи Zoom.")
    elif a.command == "list":
        rows = recordings(tok, a.days)
        out = Path(a.out).resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Записей: {len(rows)}, с расшифровкой: {sum(r['transcript'] for r in rows)} → {out}")
    else:
        rows = [r for r in json.loads(Path(a.from_list).read_text(encoding="utf-8")) if r["transcript"]][:a.limit]
        for r in rows:
            name = f"{(r['start_utc'] or '')[:10]}_{''.join(c if c.isalnum() else '_' for c in r['topic'] or 'zoom')[:40]}.vtt"
            print(download(tok, r["transcript_url"], Path(a.out).resolve() / name))


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        raise SystemExit(f"Zoom ответил {e.code}: {e.read().decode('utf-8', 'replace')[:300]}")
    except urllib.error.URLError as e:
        if "CERTIFICATE" in str(e):
            raise SystemExit("Python не видит сертификаты. Выполните: python3 -m pip install certifi — и повторите.")
        raise SystemExit(f"Нет связи с Zoom: {e.reason}")
