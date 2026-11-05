"""Свой Google для ИИ: календарь, почта, Диск, Документы и Таблицы. Вход один раз.

Вход — своим аккаунтом через приложение для компьютера (OAuth). Рядом со скриптом лежат
client_secret.json (скачан из Google Cloud) и token.json (появится после login). Оба никому не передавать.
Календарь: события и участники. Почта: чтение и черновики, отправки нет. Диск: чтение всего, изменение только своих файлов.
Приглашения людям уходят только с --attendee или --notify: это отправка, нужно поручение владельца.
"""
import argparse
import base64
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
import json
import os
from pathlib import Path
import re
import uuid

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload

ROOT = Path(__file__).resolve().parent
SCOPES = ["https://www.googleapis.com/auth/calendar.events",
          "https://www.googleapis.com/auth/gmail.readonly",
          "https://www.googleapis.com/auth/gmail.compose",
          "https://www.googleapis.com/auth/drive.readonly",
          "https://www.googleapis.com/auth/drive.file"]
FOLDER = "application/vnd.google-apps.folder"
DOC, SHEET = "application/vnd.google-apps.document", "application/vnd.google-apps.spreadsheet"
ISTOCHNIK = {".txt": "text/plain", ".md": "text/plain", ".html": "text/html", ".csv": "text/csv",
             ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
             ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}


def write_private(path, text):
    """Файл только для владельца: токен и письма не должны читаться другими пользователями компьютера."""
    path = Path(path).resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def save(rows, out):
    return write_private(out, json.dumps(rows, ensure_ascii=False, indent=2) + "\n")


def login():
    sec = ROOT / "client_secret.json"
    if not sec.exists():
        raise SystemExit("Положите client_secret.json из Google Cloud рядом со скриптом.")
    flow = InstalledAppFlow.from_client_secrets_file(str(sec), SCOPES)
    # select_account: в браузере часто открыт не тот аккаунт, выбор должен быть явным.
    creds = flow.run_local_server(port=0, prompt="select_account consent",
                                  authorization_prompt_message="Откройте ссылку, выберите нужный аккаунт и разрешите доступ:\n{url}",
                                  success_message="Готово, вкладку можно закрыть.")
    write_private(ROOT / "token.json", creds.to_json())
    return creds


def missing_scopes(saved):
    """Токен из старой версии скила: права шире не станут сами, нужен повторный вход."""
    return [s for s in SCOPES if s not in saved]


def credentials():
    tok = ROOT / "token.json"
    if not tok.exists():
        raise SystemExit("Входа нет. Владелец запускает: .venv/bin/python google_app.py login")
    if missing_scopes(json.loads(tok.read_text(encoding="utf-8")).get("scopes") or []):
        raise SystemExit("Появились новые права. Владелец запускает login ещё раз.")
    creds = Credentials.from_authorized_user_file(str(tok), SCOPES)
    if not creds.valid:
        if not creds.refresh_token:
            raise SystemExit("Вход устарел. Владелец запускает login ещё раз.")
        creds.refresh(Request())
        write_private(tok, creds.to_json())
    return creds


def service(creds, name, version):
    return build(name, version, credentials=creds, cache_discovery=False)


def file_id(s):
    m = re.search(r"/(?:d|folders)/([\w-]{20,})", s)
    return m.group(1) if m else s


def folder(d, name, parent=None):
    """Найти папку по имени или создать. Повторный вызов не плодит копии."""
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
    return d.files().export(fileId=fid, mimeType=fmt).execute().decode("utf-8").lstrip("﻿")


def drive_search(d, text, limit):
    q = text.replace("\\", "\\\\").replace("'", "\\'")
    return d.files().list(q=f"fullText contains '{q}' and trashed = false", pageSize=limit,
                          fields="files(id, name, mimeType, modifiedTime, webViewLink)").execute().get("files", [])


def moment(value):
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise SystemExit("Время должно быть в формате ISO 8601, например 2026-11-06T12:00:00+03:00.")
    if dt.tzinfo is None:
        raise SystemExit("Укажите часовой пояс времени, например +03:00.")
    return {"dateTime": dt.isoformat()}


def event_row(e):
    return {"id": e["id"], "title": e.get("summary"), "start": e["start"].get("dateTime") or e["start"].get("date"),
            "end": e["end"].get("dateTime") or e["end"].get("date"), "location": e.get("location"),
            "attendees": [x.get("email") for x in e.get("attendees", [])], "link": e.get("htmlLink")}


def event_fields(a):
    body = {}
    for key, value in (("summary", a.title), ("description", a.description), ("location", a.location)):
        if value is not None:
            body[key] = value
    for key, value in (("start", a.start), ("end", a.end)):
        if value is not None:
            body[key] = moment(value)
    return body


def events(c, days):
    now = datetime.now(timezone.utc)
    found = c.list(calendarId="primary", timeMin=now.isoformat(), timeMax=(now + timedelta(days=days)).isoformat(),
                   singleEvents=True, orderBy="startTime", maxResults=250).execute()
    return [event_row(e) for e in found.get("items", [])]


def create_event(c, a):
    body = event_fields(a)
    if a.attendee:
        body["attendees"] = [{"email": x} for x in a.attendee]
    return event_row(c.insert(calendarId="primary", body=body, sendUpdates="all" if a.attendee else "none").execute())


def update_event(c, a):
    body = event_fields(a)
    if not body:
        raise SystemExit("Укажите хотя бы одно поле для изменения.")
    return event_row(c.patch(calendarId="primary", eventId=a.id, body=body, sendUpdates="all" if a.notify else "none").execute())


def delete_event(c, a):
    c.delete(calendarId="primary", eventId=a.id, sendUpdates="all" if a.notify else "none").execute()


def mail_search(mail, query, limit):
    rows = []
    for m in mail.messages().list(userId="me", q=query, maxResults=limit).execute().get("messages", []):
        one = mail.messages().get(userId="me", id=m["id"], format="metadata", metadataHeaders=["From", "To", "Subject", "Date"]).execute()
        head = {h["name"]: h["value"] for h in one["payload"].get("headers", [])}
        rows.append({"id": m["id"], "thread": one["threadId"], "from": head.get("From"), "to": head.get("To"),
                     "subject": head.get("Subject"), "date": head.get("Date"), "snippet": one.get("snippet")})
    return rows


def parts(payload):
    yield payload
    for p in payload.get("parts", []):
        yield from parts(p)


def mail_read(mail, message_id):
    one = mail.messages().get(userId="me", id=message_id, format="full").execute()
    head = {h["name"]: h["value"] for h in one["payload"].get("headers", [])}
    text, files = [], []
    for p in parts(one["payload"]):
        if p.get("filename"):
            files.append(p["filename"])
        elif p.get("mimeType") == "text/plain" and p.get("body", {}).get("data"):
            text.append(base64.urlsafe_b64decode(p["body"]["data"]).decode("utf-8", "replace"))
    return {"id": message_id, "from": head.get("From"), "to": head.get("To"), "subject": head.get("Subject"),
            "date": head.get("Date"), "text": "\n".join(text), "attachments": files}


def mail_draft(mail, to, subject, text):
    """Только черновик: письмо отправляет сам владелец из Gmail."""
    m = EmailMessage()
    m["To"], m["Subject"] = to, subject
    m.set_content(text)
    raw = base64.urlsafe_b64encode(m.as_bytes()).decode()
    return mail.drafts().create(userId="me", body={"message": {"raw": raw}}).execute()


def cli(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("login", help="Вход в браузере: выбрать аккаунт и разрешить доступ")
    sub.add_parser("status", help="Проверить вход: аккаунт, календарь, Диск")
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
    s = sub.add_parser("drive-search", help="Найти файлы на Диске по тексту")
    s.add_argument("--text", required=True)
    s.add_argument("--limit", type=int, default=20)
    s.add_argument("--out", required=True)
    e = sub.add_parser("events", help="События основного календаря на ближайшие дни")
    e.add_argument("--days", type=int, default=7)
    e.add_argument("--out", required=True)
    n = sub.add_parser("create-event", help="Создать событие; без --attendee никому ничего не приходит")
    n.add_argument("--title", required=True)
    n.add_argument("--start", required=True, help="ISO 8601 с часовым поясом")
    n.add_argument("--end", required=True)
    n.add_argument("--description")
    n.add_argument("--location", help="Например, постоянная ссылка на встречу из PROFILE.md")
    n.add_argument("--attendee", action="append", default=[], help="Почта участника; ему уйдёт приглашение")
    u = sub.add_parser("update-event", help="Изменить событие: только указанные поля")
    u.add_argument("--id", required=True)
    u.add_argument("--title")
    u.add_argument("--start")
    u.add_argument("--end")
    u.add_argument("--description")
    u.add_argument("--location")
    u.add_argument("--notify", action="store_true", help="Сообщить участникам об изменении")
    x = sub.add_parser("delete-event", help="Удалить событие")
    x.add_argument("--id", required=True)
    x.add_argument("--notify", action="store_true", help="Сообщить участникам об отмене")
    m = sub.add_parser("mail-search", help="Найти письма: запрос как в поиске Gmail")
    m.add_argument("--query", required=True)
    m.add_argument("--limit", type=int, default=20)
    m.add_argument("--out", required=True)
    o = sub.add_parser("mail-read", help="Прочитать письмо: текст и имена вложений")
    o.add_argument("--id", required=True)
    o.add_argument("--out", required=True)
    w = sub.add_parser("mail-draft", help="Создать черновик; отправляет владелец")
    w.add_argument("--to", required=True)
    w.add_argument("--subject", required=True)
    w.add_argument("--text-file", required=True)
    return p.parse_args(argv)


def main():
    a = cli()
    creds = login() if a.command == "login" else credentials()
    if a.command in ("login", "status"):
        print("Вход подтверждён:", service(creds, "gmail", "v1").users().getProfile(userId="me").execute()["emailAddress"])
        now = datetime.now(timezone.utc).isoformat()
        print("Календарь доступен:", service(creds, "calendar", "v3").events().list(calendarId="primary", timeMin=now, maxResults=1).execute().get("timeZone"))
        print("Диск доступен:", service(creds, "drive", "v3").about().get(fields="user(emailAddress)").execute()["user"]["emailAddress"])
    elif a.command in ("folder", "create", "read", "drive-search"):
        d = service(creds, "drive", "v3")
        if a.command == "folder":
            print("Папка:", folder(d, a.name, a.parent and file_id(a.parent))["webViewLink"])
        elif a.command == "create":
            x = create(d, a.file, a.title, a.folder and file_id(a.folder))
            link = share(d, x["id"], a.share) if a.share != "none" else x["webViewLink"]
            print("Готово:", link, "" if a.share != "none" else "(доступ только у вас)")
        elif a.command == "read":
            print("Сохранено:", write_private(a.out, read(d, file_id(a.file))))
        else:
            rows = drive_search(d, a.text, a.limit)
            print("Файлов:", len(rows), "→", save(rows, a.out))
    elif a.command in ("events", "create-event", "update-event", "delete-event"):
        c = service(creds, "calendar", "v3").events()
        if a.command == "events":
            rows = events(c, a.days)
            print("Событий:", len(rows), "→", save(rows, a.out))
        elif a.command == "create-event":
            print("Создано:", json.dumps(create_event(c, a), ensure_ascii=False))
        elif a.command == "update-event":
            print("Изменено:", json.dumps(update_event(c, a), ensure_ascii=False))
        else:
            delete_event(c, a)
            print("Удалено:", a.id)
    else:
        mail = service(creds, "gmail", "v1").users()
        if a.command == "mail-search":
            rows = mail_search(mail, a.query, a.limit)
            print("Писем:", len(rows), "→", save(rows, a.out))
        elif a.command == "mail-read":
            print("Письмо →", save(mail_read(mail, a.id), a.out))
        else:
            print("Черновик создан:", mail_draft(mail, a.to, a.subject, Path(a.text_file).read_text(encoding="utf-8"))["id"])


if __name__ == "__main__":
    try:
        main()
    except HttpError as e:
        if e.resp.status == 403 and "accessNotConfigured" in str(e.content):
            raise SystemExit("Google: этот API не включён в проекте. Включите его по ссылке из SKILL.md.")
        raise SystemExit(f"Google ответил {e.resp.status}: {e.reason}")
