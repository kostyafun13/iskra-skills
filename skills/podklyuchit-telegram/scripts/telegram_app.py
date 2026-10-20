"""Свой Telegram для ИИ: чтение, вложения, неотвеченные, отправки по поручению и проверка реакций.

Память: private/pamyat.json помнит по каждому чату, где остановились, — с --novoe читаем и качаем только новое.

Отправки — по связанному с текстом поручению владельца; при неизвестном исходе повтор запрещён.
Ключи — в .env рядом со скриптом, сессия — файл personal_telegram.session там же.
"""
import argparse
import asyncio
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import re
from pathlib import Path
import uuid

from dotenv import load_dotenv
from telethon import TelegramClient, utils
from telethon.errors import RPCError
from telethon.tl.functions.messages import (CheckChatInviteRequest, GetMessageReactionsListRequest,
                                          GetScheduledHistoryRequest)
from telethon.tl.types import ChatInviteAlready, ChatInvitePeek, MessageEntityTextUrl, MessageEntityUrl

ROOT = Path(__file__).resolve().parent
INVITE = re.compile(r"(?:https?://)?t\.me/(?:\+|joinchat/)([\w-]+)")


def cli(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("login", help="Вход: номер, код, пароль — в обычном терминале владельца")
    sub.add_parser("status", help="Проверить вход")
    d = sub.add_parser("dialogs", help="Список чатов: id, название, тип")
    d.add_argument("--limit", type=int, default=50)
    d.add_argument("--out", required=True, help="Локальный JSON")
    u = sub.add_parser("unanswered", help="Личка, где последнее слово за человеком или стоит «непрочитано»")
    u.add_argument("--days", type=int, default=14)
    u.add_argument("--limit", type=int, default=200, help="Сколько последних чатов просмотреть")
    u.add_argument("--out", required=True, help="Локальный JSON")
    r = sub.add_parser("read", help="Прочитать один чат или канал")
    r.add_argument("--chat", required=True, help="ник через @, числовой id или ссылка-приглашение t.me/+…")
    r.add_argument("--limit", type=int, default=20)
    r.add_argument("--novoe", action="store_true", help="Только сообщения новее прошлого чтения — по памяти")
    r.add_argument("--liniya", help="Пометить чат в памяти: проект, пара, партнёр")
    r.add_argument("--out", required=True, help="Локальный JSON")
    g = sub.add_parser("download", help="Скачать вложения из последних сообщений чата")
    g.add_argument("--chat", required=True)
    g.add_argument("--limit", type=int, default=20)
    g.add_argument("--novoe", action="store_true", help="Только вложения новее прошлой скачки — по памяти")
    g.add_argument("--out", required=True, help="Папка для файлов")
    r = sub.add_parser("reactions", help="Реакции на конкретное сообщение; список людей — когда доступен")
    r.add_argument("--chat", required=True)
    r.add_argument("--message-id", type=int, required=True)
    r.add_argument("--limit", type=int, default=100)
    r.add_argument("--out", required=True)
    s = sub.add_parser("scheduled", help="Прочитать текущие отложенные сообщения без изменений")
    s.add_argument("--chat", required=True)
    s.add_argument("--out", required=True)
    d = sub.add_parser("prepare-send", help="Локальный план отправки с адресатом и свежим контекстом")
    d.add_argument("--chat", required=True)
    d.add_argument("--text-file", required=True)
    d.add_argument("--reply-to", type=int)
    d.add_argument("--at", help="Для напоминания: ISO 8601 с часовым поясом, например 2026-11-01T12:00:00+03:00")
    d.add_argument("--out", required=True)
    for name in ("send", "remind"):
        s = sub.add_parser(name, help="Отправить план по действительному поручению; remind требует --at в плане")
        s.add_argument("--plan", required=True)
        s.add_argument("--authorization", required=True, help="JSON: исходное поручение и привязка к плану")
    v = sub.add_parser("verify-send", help="Прочитать серверное сообщение по квитанции без повторной отправки")
    v.add_argument("--operation-id", required=True)
    v.add_argument("--out", required=True)
    return p.parse_args(argv)


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
            # Telegram задаёт смещения UTF-16: эмодзи до ссылки занимают две единицы.
            out.append(m.message.encode("utf-16-le")[e.offset * 2:(e.offset + e.length) * 2].decode("utf-16-le"))
    return [u for u in out if "/" in u]  # «README.md» Telegram тоже считает адресом


async def dialogs(client, limit):
    rows = []
    async for d in client.iter_dialogs(limit=limit):
        tip = "канал" if d.is_channel and not d.is_group else "группа" if d.is_group else "личка"
        rows.append({"id": d.id, "name": d.name, "type": tip})
    return rows


def pamyat_path():
    return ROOT / "private" / "pamyat.json"


def pamyat():
    f = pamyat_path()
    return json.loads(f.read_text(encoding="utf-8")) if f.exists() else {}


async def chat_key(client, peer):
    entity = await client.get_entity(peer)
    return str(utils.get_peer_id(entity)), utils.get_display_name(entity)


async def unanswered(client, days, limit):
    """Личка, где последнее слово за человеком или стоит пометка «непрочитано». Боты и группы — мимо."""
    since = datetime.now(timezone.utc) - timedelta(days=days)
    rows = []
    async for d in client.iter_dialogs(limit=limit):
        if not d.is_user or getattr(d.entity, "bot", False) or d.message is None:
            continue
        if d.message.date < since:
            if getattr(d, "pinned", False):
                continue
            break  # дальше чаты старше окна: список идёт от свежих к старым
        mark = bool(getattr(d.dialog, "unread_mark", False))
        if d.message.out and not mark:
            continue
        rows.append({"id": d.id, "name": d.name, "username": getattr(d.entity, "username", None),
                     "unread": d.unread_count, "unread_mark": mark, "last": message_row(d.message)})
    return rows


async def read(client, chat, limit, novoe=False, liniya=None):
    """С novoe — только сообщения новее прошлого чтения: тот же диалог второй раз целиком не качаем."""
    peer = await resolve(client, chat)
    key, name = await chat_key(client, peer)
    mem = pamyat()
    zap = mem.get(key, {})
    min_id = zap.get("read_id", 0) if novoe else 0
    # Новое читаем от старого к свежему: не влезло в limit — следующий вызов продолжит с места, середина не теряется.
    msgs = await client.get_messages(peer, limit=limit, min_id=min_id, reverse=True) if min_id else await client.get_messages(peer, limit=limit)
    rows = [message_row(m) for m in msgs]
    zap.update({"name": name, "read_at": datetime.now(timezone.utc).isoformat()})
    if rows:
        zap["read_id"] = max(zap.get("read_id", 0), max(r["id"] for r in rows))
    if liniya:
        zap["liniya"] = liniya
    mem[key] = zap
    save(mem, pamyat_path())
    return rows


def reaction_row(reaction):
    if hasattr(reaction, "emoticon"):
        return {"emoji": reaction.emoticon}
    if hasattr(reaction, "document_id"):
        return {"custom_emoji_id": reaction.document_id}
    return {"type": type(reaction).__name__}


def message_row(m):
    return {"id": m.id, "date": m.date.isoformat(), "out": bool(m.out),
            "sender_id": m.sender_id, "text": m.message or "", "links": ssylki(m),
            "reply_to_msg_id": getattr(m, "reply_to_msg_id", None),
            "file": m.file.name if m.file and m.file.name else None,
            "reactions": [{**reaction_row(x.reaction), "count": x.count}
                          for x in getattr(getattr(m, "reactions", None), "results", [])]}


async def reactions(client, chat, message_id, limit):
    peer = await resolve(client, chat)
    m = await client.get_messages(peer, ids=message_id)
    if not m:
        raise SystemExit("Сообщение не найдено в указанном чате.")
    result = {"chat_id": m.chat_id, "message": message_row(m), "people": [],
              "people_available": False, "people_complete": False}
    info = getattr(m, "reactions", None)
    if not info or not getattr(info, "can_see_list", False):
        result["note"] = "Telegram не предоставляет полный список людей; отсутствие списка не означает отсутствие реакции."
        return result
    offset = None
    seen = set()
    try:
        while len(result["people"]) < limit:
            batch = await client(GetMessageReactionsListRequest(
                peer=await client.get_input_entity(peer), id=message_id,
                limit=min(100, limit - len(result["people"])), offset=offset))
            users = {u.id: u for u in batch.users}
            for item in batch.reactions:
                pid = utils.get_peer_id(item.peer_id)
                user = users.get(pid)
                result["people"].append({"peer_id": pid, "username": getattr(user, "username", None),
                    "name": " ".join(filter(None, [getattr(user, "first_name", None), getattr(user, "last_name", None)])),
                    "date": item.date.isoformat() if item.date else None, **reaction_row(item.reaction)})
            result["people_available"] = True
            result["total"] = batch.count
            offset = batch.next_offset
            if not offset:
                result["people_complete"] = len(result["people"]) >= batch.count
                break
            if offset in seen:
                break
            seen.add(offset)
    except RPCError as e:
        result["note"] = "Telegram ограничил список людей: " + type(e).__name__
    return result


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def scheduled_time(value):
    if value is None:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        raise SystemExit("Время должно быть ISO 8601 с часовым поясом.")
    if dt.tzinfo is None or dt.utcoffset() is None:
        raise SystemExit("Укажите часовой пояс времени, например +03:00.")
    return dt.astimezone(timezone.utc)


def validate_plan(plan):
    if plan.get("version") != 1 or not re.fullmatch(r"[a-f0-9]{32}", str(plan.get("id", ""))):
        raise SystemExit("Неверный план: создайте его через prepare-send.")
    for key in ("account_id", "chat_id", "context_last_id"):
        if type(plan.get(key)) is not int:
            raise SystemExit("Неверный идентификатор в плане: " + key)
    text = plan.get("text")
    if not isinstance(text, str) or not text.strip() or len(text.encode("utf-16-le")) // 2 > 4096:
        raise SystemExit("Текст должен содержать от 1 до 4096 единиц UTF-16; автоматически его не сокращаю.")
    if plan.get("text_sha256") != digest(text):
        raise SystemExit("Текст плана изменён после подготовки.")
    if plan.get("reply_to") is not None and (type(plan["reply_to"]) is not int or plan["reply_to"] < 1):
        raise SystemExit("Неверный reply_to.")
    scheduled_time(plan.get("schedule"))


def check_authorization(plan, authorization):
    # Это механическая привязка. Подлинность и смысл исходного поручения проверяет агент.
    if not all(isinstance(authorization.get(k), str) and authorization[k].strip()
               for k in ("source", "owner_text")):
        raise SystemExit("Нужно дословное поручение владельца и указатель на его исходное сообщение.")
    for key in ("account_id", "chat_id", "text_sha256", "reply_to", "schedule"):
        if key not in authorization or authorization[key] != plan.get(key):
            raise SystemExit("Поручение не связано с параметром плана: " + key)


async def prepare_send(client, a):
    text = Path(a.text_file).read_text(encoding="utf-8")
    entity = await client.get_entity(await resolve(client, a.chat))
    me = await client.get_me()
    context = await read(client, utils.get_peer_id(entity), 20)
    at = scheduled_time(a.at)
    if at and at <= datetime.now(timezone.utc):
        raise SystemExit("Время напоминания уже прошло.")
    plan = {"version": 1, "id": uuid.uuid4().hex, "account_id": me.id,
            "chat_id": utils.get_peer_id(entity), "recipient": utils.get_display_name(entity),
            "username": getattr(entity, "username", None), "text": text, "text_sha256": digest(text),
            "reply_to": a.reply_to, "schedule": at.isoformat() if at else None,
            "context_last_id": context[0]["id"] if context else 0, "context": context}
    validate_plan(plan)
    if a.reply_to and not await client.get_messages(entity, ids=a.reply_to):
        raise SystemExit("Сообщение для ответа не найдено в указанном чате.")
    return plan


def operation_path(operation_id):
    if not re.fullmatch(r"[a-f0-9]{32}", operation_id):
        raise SystemExit("Неверный operation-id.")
    return ROOT / "private" / "operations" / (operation_id + ".json")


async def verify_receipt(client, record):
    if (await client.get_me()).id != record["account_id"]:
        raise SystemExit("Квитанция относится к другому аккаунту Telegram.")
    if not record.get("message_id"):
        raise SystemExit("Исход неизвестен. Сначала прочитайте свежий чат и отложенные сообщения. Повтор не разрешён.")
    peer = record["chat_id"]
    if record.get("schedule"):
        scheduled = await client(GetScheduledHistoryRequest(peer=await client.get_input_entity(peer), hash=0))
        m = next((x for x in scheduled.messages if x.id == record["message_id"]), None)
        # После выхода у сообщения другой ID: прежнюю отложку не выдаём за доставленную.
    else:
        m = await client.get_messages(peer, ids=record["message_id"])
    if (not m or not m.out or m.chat_id != peer or digest(m.message or "") != record["text_sha256"]
            or getattr(m, "reply_to_msg_id", None) != record.get("reply_to")):
        raise SystemExit("Серверное сообщение не совпало с планом либо уже изменилось. Повтор не разрешён.")
    if record.get("schedule") and abs((m.date - scheduled_time(record["schedule"])).total_seconds()) > 1:
        raise SystemExit("Время отложенного сообщения не совпало с планом. Повтор не разрешён.")
    return {**record, "status": "scheduled_verified" if record.get("schedule") else "sent_verified",
            "read_back": message_row(m)}


async def send_plan(client, plan, authorization, remind=False):
    validate_plan(plan)
    check_authorization(plan, authorization)
    if remind and not plan.get("schedule"):
        raise SystemExit("Для remind подготовьте план с --at.")
    if (await client.get_me()).id != plan["account_id"]:
        raise SystemExit("Подключён другой аккаунт Telegram.")
    target = operation_path(plan["id"])
    fingerprint = digest(json.dumps(plan, ensure_ascii=False, sort_keys=True))
    if target.exists():
        old = json.loads(target.read_text(encoding="utf-8"))
        if old.get("fingerprint") != fingerprint:
            raise SystemExit("План с этим ID уже использован с другим содержанием.")
        checked = await verify_receipt(client, old)
        save(checked, target)
        return checked
    latest = await client.get_messages(plan["chat_id"], limit=1)
    if (latest[0].id if latest else 0) != plan["context_last_id"]:
        raise SystemExit("В чате есть новые сообщения. Перечитайте диалог и заново подготовьте план; прежнее поручение само не отменяется.")
    at = scheduled_time(plan.get("schedule"))
    if at and at <= datetime.now(timezone.utc):
        raise SystemExit("Время напоминания уже прошло.")
    if plan.get("reply_to") and not await client.get_messages(plan["chat_id"], ids=plan["reply_to"]):
        raise SystemExit("Сообщение для ответа больше недоступно.")
    record = {"operation_id": plan["id"], "fingerprint": fingerprint, "status": "outcome_unknown",
              "account_id": plan["account_id"], "chat_id": plan["chat_id"], "recipient": plan["recipient"],
              "text_sha256": plan["text_sha256"], "reply_to": plan.get("reply_to"), "schedule": plan.get("schedule"),
              "authorization_source": authorization["source"], "started_at": datetime.now(timezone.utc).isoformat()}
    # Запись ДО сети удерживает неизвестный исход, включая остановку процесса.
    save(record, target)
    sent = await client.send_message(plan["chat_id"], plan["text"], reply_to=plan.get("reply_to"),
                                     schedule=at, parse_mode=None, link_preview=False)
    record["message_id"] = sent.id
    save(record, target)
    checked = await verify_receipt(client, record)
    save(checked, target)
    return checked


async def download(client, chat, limit, out, novoe=False):
    peer = await resolve(client, chat)
    key, name = await chat_key(client, peer)
    mem = pamyat()
    zap = mem.get(key, {"name": name})
    min_id = zap.get("files_id", 0) if novoe else 0
    out.mkdir(parents=True, exist_ok=True)
    saved, top = [], min_id
    msgs = await client.get_messages(peer, limit=limit, min_id=min_id, reverse=True) if min_id else await client.get_messages(peer, limit=limit)
    for m in msgs:
        top = max(top, m.id)
        if m.document:
            saved.append(str(await m.download_media(file=out)))
    zap["files_id"] = top
    mem[key] = zap
    save(mem, pamyat_path())
    return saved


def save(rows, out):
    out = Path(out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    temporary = out.with_name(out.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
        os.replace(temporary, out)
    finally:
        temporary.unlink(missing_ok=True)
    return out


def _session_lock():
    path = ROOT / ".telegram.lock"
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise SystemExit("Сессия уже занята. После аварии сначала проверьте процесс из .telegram.lock; не снимайте живую блокировку.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(str(os.getpid()))
        yield
    finally:
        path.unlink(missing_ok=True)


session_lock = contextmanager(_session_lock)  # без декоратора: строку с «@» проверка публикации путает с ником


async def run(a):
    if getattr(a, "limit", 1) not in range(1, 201):
        raise SystemExit("limit — от 1 до 200.")
    if hasattr(a, "message_id") and a.message_id < 1:
        raise SystemExit("message-id должен быть положительным.")
    if a.command in ("send", "remind"):
        plan = json.loads(Path(a.plan).read_text(encoding="utf-8"))
        authorization = json.loads(Path(a.authorization).read_text(encoding="utf-8"))
        validate_plan(plan)
        check_authorization(plan, authorization)
    load_dotenv(ROOT / ".env")
    api_id = os.environ.get("TELEGRAM_API_ID", "")
    api_hash = os.environ.get("TELEGRAM_API_HASH", "")
    if not api_id.isdigit() or not api_hash:
        raise SystemExit("Заполните TELEGRAM_API_ID и TELEGRAM_API_HASH в файле .env рядом со скриптом.")
    client = TelegramClient(str(ROOT / "personal_telegram"), int(api_id), api_hash,
                            receive_updates=False, request_retries=0, connection_retries=2,
                            flood_sleep_threshold=0, raise_last_call_error=True)
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
        elif a.command == "unanswered":
            print("Ждут ответа:", len(rows := await unanswered(client, a.days, a.limit)), "→", save(rows, a.out))
        elif a.command == "read":
            rows = await read(client, a.chat, a.limit, a.novoe, a.liniya)
            print("Новых сообщений:" if a.novoe else "Сообщений:", len(rows), "→", save(rows, a.out))
            if a.novoe and len(rows) == a.limit:
                print("Новых больше лимита — повторите команду: продолжу с места, где остановился.")
        elif a.command == "reactions":
            print("Реакции →", save(await reactions(client, a.chat, a.message_id, a.limit), a.out))
        elif a.command == "scheduled":
            peer = await resolve(client, a.chat)
            result = await client(GetScheduledHistoryRequest(peer=await client.get_input_entity(peer), hash=0))
            print("Отложки →", save([message_row(m) for m in result.messages], a.out))
        elif a.command == "prepare-send":
            print("План →", save(await prepare_send(client, a), a.out))
        elif a.command in ("send", "remind"):
            receipt = await send_plan(client, plan, authorization, remind=a.command == "remind")
            print(receipt["status"], "→", operation_path(plan["id"]))
        elif a.command == "verify-send":
            record = json.loads(operation_path(a.operation_id).read_text(encoding="utf-8"))
            print("Проверка →", save(await verify_receipt(client, record), a.out))
        elif a.command == "download":
            files = await download(client, a.chat, a.limit, Path(a.out).resolve(), a.novoe)
            print("Файлов:", len(files), *files, sep="\n")
    finally:
        await client.disconnect()


if __name__ == "__main__":
    try:
        arguments = cli()
        with session_lock():
            asyncio.run(run(arguments))
    except SystemExit:
        raise
    except Exception as e:
        raise SystemExit(f"Ошибка: {type(e).__name__}. {e}")
