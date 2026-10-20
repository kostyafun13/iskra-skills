"""Индекс своей базы: личка Telegram → карточка на каждого человека, поиск и совпадения с папками участников.

Работает через уже подключённый Telegram (скил podklyuchit-telegram): та же сессия и тот же .env,
по умолчанию в соседней папке connections/telegram. Только чтение — никому не пишет.
Докачка: база помнит последнее сообщение каждого чата, второй запуск читает только новое.
Всё хранится локально в private/indeks.sqlite. Наружу — только таблица без имён и контактов.
"""
import argparse
import asyncio
import csv
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import re
import sqlite3
import statistics

ROOT = Path(__file__).resolve().parent
DB = ROOT / "private" / "indeks.sqlite"
TG = Path(os.environ.get("TELEGRAM_DIR", ROOT.parent / "telegram"))

SCHEMA = """
create table if not exists people(id integer primary key, name text, username text, last_id integer default 0,
  msgs integer default 0, first_at text, last_at text, last_out integer, zvonki integer default 0,
  teplota text, stil text, kompaniya text, rol text, chem_polezen text, zametki text, updated_at text);
create table if not exists msgs(chat_id integer, id integer, date text, out integer, dlina integer,
  golos integer, tekst text, primary key(chat_id, id));
"""
TY = re.compile(r"\b(ты|тебе|тебя|тобой|твой|твоя|твоё|твои)\b", re.I)
VY = re.compile(r"\b(вы|вам|вас|вами|ваш|ваша|ваше|ваши)\b", re.I)
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿]")
STOP = set("который которые которая также чтобы через между после перед более менее очень может можно нужно этого этой этих".split())


def db():
    DB.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(DB)
    c.executescript(SCHEMA)
    return c


def stil(rows):
    """Как человек привык общаться — по фактам переписки, чтобы интро звучало нативно.
    rows: (date ISO, out 0/1, dlina, golos 0/1, tekst) по возрастанию даты."""
    ego = [r for r in rows if not r[1]]
    moi = [r for r in rows if r[1]]
    if not ego:
        return "сам не писал"
    ty = sum(len(TY.findall(r[4] or "")) for r in rows)
    vy = sum(len(VY.findall(r[4] or "")) for r in rows)
    chasti = ["на «ты»" if ty > vy else "на «вы»" if vy > ty else "обращение не ясно"]
    tekst = [r[2] for r in ego if not r[3]]
    if tekst:
        med = int(statistics.median(tekst))
        chasti.append(("коротко" if med < 60 else "развёрнуто" if med > 250 else "средне") + f", ~{med} знаков")
    golos = sum(r[3] for r in ego) / len(ego)
    if golos >= 0.2:
        chasti.append(f"голосом {round(golos * 100)} %")
    if sum(1 for r in ego if EMOJI.search(r[4] or "")) / len(ego) >= 0.3:
        chasti.append("с эмодзи")
    otvety, zhdu = [], None
    for r in rows:  # скорость ответа: от моего сообщения до его первого ответа
        t = datetime.fromisoformat(r[0])
        if r[1] and zhdu is None:
            zhdu = t
        elif not r[1] and zhdu is not None:
            otvety.append((t - zhdu).total_seconds() / 3600)
            zhdu = None
    if otvety:
        h = statistics.median(otvety)
        chasti.append("отвечает " + ("за минуты" if h < 0.25 else f"~{round(h)} ч" if h < 48 else f"~{round(h / 24)} дн"))
    chasy = [datetime.fromisoformat(r[0]).astimezone().hour for r in ego]
    utro = sum(5 <= h < 12 for h in chasy)
    den = sum(12 <= h < 18 for h in chasy)
    vecher = len(chasy) - utro - den
    chasti.append("чаще " + max((utro, "утром"), (den, "днём"), (vecher, "вечером"))[1])
    if not moi:
        chasti.append("ты ему не отвечал")
    return " · ".join(chasti)


def teplota(last_at, last_out, zvonki, msgs, now=None):
    """Горячий — созванивались в Telegram или переписка от 200 сообщений; тёплый — живой диалог за 30 дней;
    иначе «оживить» — сначала напомнить о себе, в верхнюю пятёрку подборки не ставить."""
    now = now or datetime.now(timezone.utc)
    if zvonki or msgs >= 200:
        return "горячий"
    if last_at and now - datetime.fromisoformat(last_at) <= timedelta(days=30):
        return "тёплый"
    return "оживить"


def obnovit_kartochku(c, pid):
    rows = c.execute("select date, out, dlina, golos, tekst from msgs where chat_id=? order by date", (pid,)).fetchall()
    p = c.execute("select last_at, last_out, zvonki, msgs from people where id=?", (pid,)).fetchone()
    c.execute("update people set stil=?, teplota=?, updated_at=? where id=?",
              (stil(rows), teplota(*p), datetime.now(timezone.utc).isoformat(), pid))


async def sobrat(client, c, dney, minimum, limit):
    """Личка с людьми (не боты, не группы) за окно дней. Уже собранное не качаем: только новее last_id."""
    since = datetime.now(timezone.utc) - timedelta(days=dney)
    novyh = lyudey = 0
    async for d in client.iter_dialogs(limit=limit):
        if not d.is_user or getattr(d.entity, "bot", False) or d.message is None:
            continue
        if d.message.date < since:
            if getattr(d, "pinned", False):
                continue
            break  # дальше чаты старше окна: список идёт от свежих к старым
        e = d.entity
        row = c.execute("select last_id from people where id=?", (e.id,)).fetchone()
        last_id = row[0] if row else 0
        if row is None:
            c.execute("insert into people(id, name, username) values(?,?,?)",
                      (e.id, d.name, getattr(e, "username", None)))
        prishlo = 0
        kwargs = {"reverse": True, "min_id": last_id} if last_id else {"reverse": True, "offset_date": since}
        async for m in client.iter_messages(e, **kwargs):
            if getattr(m, "action", None) is not None:
                if "PhoneCall" in type(m.action).__name__:
                    c.execute("update people set zvonki=zvonki+1 where id=?", (e.id,))
                continue
            golos = int(bool(getattr(m, "voice", None)))
            c.execute("insert or ignore into msgs values(?,?,?,?,?,?,?)",
                      (e.id, m.id, m.date.isoformat(), int(bool(m.out)), len(m.message or ""), golos, (m.message or "")[:500]))
            c.execute("update people set last_id=max(last_id, ?), msgs=msgs+1, first_at=coalesce(first_at, ?), "
                      "last_at=?, last_out=? where id=?",
                      (m.id, m.date.isoformat(), m.date.isoformat(), int(bool(m.out)), e.id))
            prishlo += 1
        if c.execute("select msgs from people where id=?", (e.id,)).fetchone()[0] < minimum:
            continue
        if prishlo:
            obnovit_kartochku(c, e.id)
            novyh += prishlo
        lyudey += 1
        c.commit()
    c.commit()
    return lyudey, novyh


def slova(tekst):
    return {w for w in re.findall(r"[a-zа-яё0-9]{4,}", tekst.lower()) if w not in STOP}


def sovpadeniya(c, zapros, top):
    """Совпадения запроса с карточками: компания, роль, чем полезен, заметки — то, что ИИ дописал в карточки."""
    klyuchi = {w[:6] for w in slova(zapros)}
    out = []
    for r in c.execute("select id, name, kompaniya, rol, chem_polezen, zametki, teplota, stil from people"):
        tekst = " ".join(x or "" for x in r[2:6]).lower()
        hit = sorted({k for k in klyuchi if k in tekst})
        if hit:
            out.append((len(hit) + (r[6] == "горячий") * 0.5 + (r[6] == "тёплый") * 0.25, r, hit))
    out.sort(key=lambda x: -x[0])
    return out[:top]


def zapisat(rows, put, s_imenami):
    put.parent.mkdir(parents=True, exist_ok=True)
    with open(put, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow((["Имя"] if s_imenami else []) + ["Компания", "Роль", "Чем полезен", "Теплота", "Как общается", "Совпало по"])
        for _, r, hit in rows:
            w.writerow(([r[1]] if s_imenami else []) + [r[2] or "", r[3] or "", r[4] or "", r[6] or "", r[7] or "", ", ".join(hit)])
    return put


def cli(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("sobrat", help="Собрать или докачать индекс из лички Telegram")
    s.add_argument("--dney", type=int, default=365)
    s.add_argument("--min", type=int, default=5, help="Карточка — от N сообщений в переписке")
    s.add_argument("--limit", type=int, default=500, help="Сколько последних чатов просмотреть")
    sub.add_parser("stat", help="Сколько людей и как распределена теплота")
    o = sub.add_parser("obrazec", help="Последние сообщения человека — ИИ читает и заполняет карточку")
    o.add_argument("--kto", required=True, help="id или ник без @")
    o.add_argument("--n", type=int, default=30)
    z = sub.add_parser("zapolnit", help="Дописать в карточку то, что ИИ понял из переписки")
    z.add_argument("--kto", required=True)
    for pole in ("kompaniya", "rol", "chem", "zametki", "stil"):
        z.add_argument(f"--{pole}")
    n = sub.add_parser("pustye", help="Карточки без компании — их ИИ заполняет первыми")
    n.add_argument("--n", type=int, default=20)
    q = sub.add_parser("poisk", help="Найти людей под запрос")
    q.add_argument("zapros")
    q.add_argument("--top", type=int, default=15)
    v = sub.add_parser("sovpadeniya", help="Совпадения с документом «Кого ищем» из папки участника")
    v.add_argument("--fayl", required=True, help="Документ «Кого ищем», .md или .txt")
    v.add_argument("--top", type=int, default=30)
    v.add_argument("--out", required=True, help="Таблица только для тебя; рядом появится версия без имён")
    return p.parse_args(argv)


def najti(c, kto):
    kto = kto.lstrip("@")
    r = c.execute("select id, name from people where id=? or lower(username)=lower(?)",
                  (int(kto) if kto.isdigit() else -1, kto)).fetchone()
    if not r:
        raise SystemExit("Такого человека в индексе нет. Сначала sobrat.")
    return r


def klient():
    from dotenv import load_dotenv
    from telethon import TelegramClient
    load_dotenv(TG / ".env")
    api_id, api_hash = os.environ.get("TELEGRAM_API_ID", ""), os.environ.get("TELEGRAM_API_HASH", "")
    if not api_id.isdigit() or not api_hash:
        raise SystemExit(f"Нет ключей Telegram в {TG / '.env'}. Сначала скил podklyuchit-telegram.")
    return TelegramClient(str(TG / "personal_telegram"), int(api_id), api_hash, receive_updates=False)


async def run(a):
    c = db()
    if a.command == "sobrat":
        lock = TG / ".telegram.lock"
        if lock.exists():
            raise SystemExit("Сессия Telegram занята другим процессом. Дождитесь его и повторите.")
        lock.write_text(str(os.getpid()))
        cl = klient()
        try:
            await cl.connect()
            if not await cl.is_user_authorized():
                raise SystemExit("Telegram не подключён. Сначала login в скиле podklyuchit-telegram.")
            lyudey, novyh = await sobrat(cl, c, a.dney, a.min, a.limit)
        finally:
            await cl.disconnect()
            lock.unlink(missing_ok=True)
        print(f"Карточек: {lyudey}, новых сообщений докачано: {novyh} → {DB}")
    elif a.command == "stat":
        vsego = c.execute("select count(*) from people where stil is not null").fetchone()[0]
        t = dict(c.execute("select teplota, count(*) from people where stil is not null group by teplota").fetchall())
        pust = c.execute("select count(*) from people where stil is not null and kompaniya is null").fetchone()[0]
        print(f"Людей: {vsego} · горячих {t.get('горячий', 0)} · тёплых {t.get('тёплый', 0)} · "
              f"оживить {t.get('оживить', 0)} · без компании {pust}")
    elif a.command == "obrazec":
        pid, name = najti(c, a.kto)
        print(f"# {name}")
        rows = c.execute("select date, out, golos, tekst from msgs where chat_id=? order by date desc limit ?", (pid, a.n))
        for d, out, golos, tekst in rows.fetchall()[::-1]:
            print(f"[{d[:10]}] {'я' if out else 'он'}: {'(голосовое) ' if golos else ''}{tekst}")
    elif a.command == "zapolnit":
        pid, name = najti(c, a.kto)
        polya = {"kompaniya": a.kompaniya, "rol": a.rol, "chem_polezen": a.chem, "zametki": a.zametki, "stil": a.stil}
        for k, v in polya.items():
            if v:
                c.execute(f"update people set {k}=? where id=?", (v, pid))
        c.commit()
        print("Карточка обновлена:", name)
    elif a.command == "pustye":
        for pid, name, msgs, tep in c.execute("select id, name, msgs, teplota from people where stil is not null "
                                              "and kompaniya is null order by msgs desc limit ?", (a.n,)):
            print(pid, name, f"сообщений {msgs}", tep, sep=" · ")
    elif a.command == "poisk":
        for _, r, hit in sovpadeniya(c, a.zapros, a.top):
            print(r[1], r[2] or "—", r[3] or "—", r[6], "совпало: " + ", ".join(hit), sep=" · ")
    elif a.command == "sovpadeniya":
        rows = sovpadeniya(c, Path(a.fayl).read_text(encoding="utf-8"), a.top)
        out = Path(a.out).resolve()
        zapisat(rows, out, True)
        bez = zapisat(rows, out.with_name(out.stem + "_bez_imen" + out.suffix), False)
        print(f"Совпадений: {len(rows)} → {out} (только у тебя) · {bez} — можно отдавать участнику")


if __name__ == "__main__":
    asyncio.run(run(cli()))
