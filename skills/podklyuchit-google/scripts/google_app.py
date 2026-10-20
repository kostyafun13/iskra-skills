"""Свой Google Диск для ИИ: вход один раз, папка, документ или таблица из файла, ссылка, чтение.

Вход — своим аккаунтом через приложение для компьютера (OAuth). Рядом со скриптом лежат
client_secret.json (скачан из Google Cloud) и token.json (появится после login).
Права — drive.file: скрипт видит только папки и файлы, которые создал сам или которые вы ему открыли.
"""
import argparse
import re
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

ROOT = Path(__file__).resolve().parent
SCOPES = ["https://www.googleapis.com/auth/drive.file"]
FOLDER = "application/vnd.google-apps.folder"
DOC, SHEET = "application/vnd.google-apps.document", "application/vnd.google-apps.spreadsheet"
ISTOCHNIK = {".txt": "text/plain", ".md": "text/plain", ".html": "text/html", ".csv": "text/csv",
             ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
             ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}


def drive(login=False):
    tok, sec = ROOT / "token.json", ROOT / "client_secret.json"
    creds = Credentials.from_authorized_user_file(str(tok), SCOPES) if tok.exists() else None
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    if not creds or not creds.valid:
        if not login:
            raise SystemExit("Входа нет. Владелец запускает: python google_app.py login")
        if not sec.exists():
            raise SystemExit("Положите client_secret.json из Google Cloud рядом со скриптом.")
        creds = InstalledAppFlow.from_client_secrets_file(str(sec), SCOPES).run_local_server(port=0)
    tok.write_text(creds.to_json(), encoding="utf-8")
    return build("drive", "v3", credentials=creds, cache_discovery=False)


def file_id(s):
    m = re.search(r"/(?:d|folders)/([\w-]{20,})", s)
    return m.group(1) if m else s


def folder(d, name, parent=None):
    """Найти свою папку по имени или создать. Повторный вызов не плодит копии."""
    q = f"mimeType='{FOLDER}' and name='{name.replace(chr(39), chr(92) + chr(39))}' and trashed=false"
    if parent:
        q += f" and '{parent}' in parents"
    found = d.files().list(q=q, fields="files(id,webViewLink)").execute()["files"]
    if found:
        return found[0]
    body = {"name": name, "mimeType": FOLDER, **({"parents": [parent]} if parent else {})}
    return d.files().create(body=body, fields="id,webViewLink").execute()


def create(d, path, title, parent=None):
    """Файл → Google Документ (.txt .md .html .docx) или Google Таблица (.csv .xlsx)."""
    path = Path(path)
    src = ISTOCHNIK.get(path.suffix.lower())
    if not src:
        raise SystemExit("Поддерживаются: " + " ".join(ISTOCHNIK))
    body = {"name": title or path.stem, "mimeType": SHEET if path.suffix.lower() in (".csv", ".xlsx") else DOC,
            **({"parents": [parent]} if parent else {})}
    return d.files().create(body=body, media_body=MediaFileUpload(str(path), mimetype=src),
                            fields="id,webViewLink").execute()


def share(d, fid, role):
    """Доступ по ссылке: reader — читать, commenter — комментировать, writer — править."""
    d.permissions().create(fileId=fid, body={"type": "anyone", "role": role}).execute()
    return d.files().get(fileId=fid, fields="webViewLink").execute()["webViewLink"]


def read(d, fid):
    mime = d.files().get(fileId=fid, fields="mimeType").execute()["mimeType"]
    fmt = "text/csv" if mime == SHEET else "text/plain"
    return d.files().export(fileId=fid, mimeType=fmt).execute().decode("utf-8").lstrip("\ufeff")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("login", help="Вход в браузере, один раз")
    sub.add_parser("status", help="Проверить вход")
    f = sub.add_parser("folder", help="Найти или создать папку")
    f.add_argument("--name", required=True)
    f.add_argument("--parent", help="id или ссылка родительской папки")
    c = sub.add_parser("create", help="Документ или таблица из локального файла")
    c.add_argument("--file", required=True)
    c.add_argument("--title")
    c.add_argument("--folder", help="id или ссылка папки")
    c.add_argument("--share", choices=["none", "reader", "commenter", "writer"], default="none")
    r = sub.add_parser("read", help="Текст документа или CSV таблицы")
    r.add_argument("--file", required=True, help="id или ссылка")
    r.add_argument("--out", required=True)
    a = p.parse_args()
    d = drive(login=a.command == "login")
    if a.command in ("login", "status"):
        about = d.about().get(fields="user(emailAddress)").execute()
        print("Вход подтверждён:", about["user"]["emailAddress"])
    elif a.command == "folder":
        x = folder(d, a.name, a.parent and file_id(a.parent))
        print("Папка:", x["webViewLink"])
    elif a.command == "create":
        x = create(d, a.file, a.title, a.folder and file_id(a.folder))
        link = share(d, x["id"], a.share) if a.share != "none" else x["webViewLink"]
        print("Готово:", link, "" if a.share != "none" else "(доступ только у вас)")
    else:
        out = Path(a.out).resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(read(d, file_id(a.file)), encoding="utf-8")
        print("Сохранено:", out)


if __name__ == "__main__":
    main()
