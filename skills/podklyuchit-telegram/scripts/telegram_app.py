"""Свой Telegram для ИИ: вход один раз, список чатов, чтение и скачивание вложений.

Только чтение. Отправки людям в скрипте нет — их владелец настраивает отдельно.
Ключи — в .env рядом со скриптом, сессия — файл personal_telegram.session там же.
"""
import argparse
import asyncio
import json
import os
import re
from pathlib import Path

from dotenv import load_dotenv
from telethon import TelegramClient
from telethon.tl.functions.messages import CheckChatInviteRequest
from telethon.tl.types import ChatInviteAlready, ChatInvitePeek, MessageEntityTextUrl, MessageEntityUrl

ROOT = Path(__file__).resolve().parent
INVITE = re.compile(r"(?:https?://)?t\.me/(?:\+|joinchat/)([\w-]+)")


def cli():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("login", help="Вход: номер, код, пароль — в обычном терминале владельца")
    sub.add_parser("status", help="Проверить вход")
    d = sub.add_parser("dialogs", help="Список чатов: id, название, тип")
    d.add_argument("--limit", type=int, default=50)
    d.add_argument("--out", required=True, help="Локальный JSON")
    r = sub.add_parser("read", help="Прочитать один чат или канал")
    r.add_argument("--chat", required=True, help="ник через @, числовой id или ссылка-приглашение t.me/+…")
    r.add_argument("--limit", type=int, default=20)
    r.add_argument("--out", required=True, help="Локальный JSON")
    g = sub.add_parser("download", help="Скачать вложения из последних сообщений чата")
    g.add_argument("--chat", required=True)
    g.add_argument("--limit", type=int, default=20)
    g.add_argument("--out", required=True, help="Папка для файлов")
    return p.parse_args()


async def resolve(client, chat):
    """Ник, id или ссылка-приглашение. В канал по ссылке не вступает — это делает владелец."""
    chat = str(chat)
    m = INVITE.search(chat)
    if m:
        info = await client(CheckChatInviteRequest(m.group(1)))
        if isinstance(info, (ChatInviteAlready, ChatInvitePeek)):
            return info.chat
        raise SystemExit("Вы ещё не в этом канале. Откройте ссылку в Telegram, вступите и повторите.")
    return int(chat) if chat.lstrip("-").isdigit() else chat


def ssylki(m):
    """Адреса из текста и из гиперссылок на словах — иначе ссылка на GitHub в посте теряется."""
    out = []
    for e in m.entities or []:
        if isinstance(e, MessageEntityTextUrl):
            out.append(e.url)
        elif isinstance(e, MessageEntityUrl):
            out.append(m.message[e.offset:e.offset + e.length])
    return [u for u in out if "/" in u]  # «README.md» Telegram тоже считает адресом


async def dialogs(client, limit):
    rows = []
    async for d in client.iter_dialogs(limit=limit):
        tip = "канал" if d.is_channel and not d.is_group else "группа" if d.is_group else "личка"
        rows.append({"id": d.id, "name": d.name, "type": tip})
    return rows


async def read(client, chat, limit):
    peer = await resolve(client, chat)
    rows = []
    for m in await client.get_messages(peer, limit=limit):
        rows.append({"id": m.id, "date": m.date.isoformat(), "out": m.out, "text": m.message or "",
                     "links": ssylki(m), "file": m.file.name if m.file and m.file.name else None})
    return rows


async def download(client, chat, limit, out):
    peer = await resolve(client, chat)
    out.mkdir(parents=True, exist_ok=True)
    saved = []
    for m in await client.get_messages(peer, limit=limit):
        if m.document:
            saved.append(str(await m.download_media(file=out)))
    return saved


def save(rows, out):
    out = Path(out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return out


async def run(a):
    load_dotenv(ROOT / ".env")
    api_id = os.environ.get("TELEGRAM_API_ID", "")
    api_hash = os.environ.get("TELEGRAM_API_HASH", "")
    if not api_id.isdigit() or not api_hash:
        raise SystemExit("Заполните TELEGRAM_API_ID и TELEGRAM_API_HASH в файле .env рядом со скриптом.")
    if getattr(a, "limit", 1) not in range(1, 201):
        raise SystemExit("limit — от 1 до 200.")
    client = TelegramClient(str(ROOT / "personal_telegram"), int(api_id), api_hash,
                            receive_updates=False, request_retries=2, connection_retries=2)
    try:
        if a.command == "login":
            await client.start()
        else:
            await client.connect()
            if not await client.is_user_authorized():
                raise SystemExit("Входа нет. Владелец запускает login в обычном терминале.")
        if a.command in ("login", "status"):
            me = await client.get_me()
            print("Вход подтверждён:", me.first_name, "@" + me.username if me.username else "")
        elif a.command == "dialogs":
            print("Чатов:", len(rows := await dialogs(client, a.limit)), "→", save(rows, a.out))
        elif a.command == "read":
            print("Сообщений:", len(rows := await read(client, a.chat, a.limit)), "→", save(rows, a.out))
        elif a.command == "download":
            files = await download(client, a.chat, a.limit, Path(a.out).resolve())
            print("Файлов:", len(files), *files, sep="\n")
    finally:
        await client.disconnect()


if __name__ == "__main__":
    try:
        asyncio.run(run(cli()))
    except SystemExit:
        raise
    except Exception as e:
        raise SystemExit(f"Ошибка: {type(e).__name__}. {e}")
