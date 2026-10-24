"""Индекс своей базы: единая база твоих данных — карточка на каждого человека, сканирование под продукты, обмен в группе.

Принцип: мусор на входе — мусор на выходе; отличные данные на входе — отличный результат. Источники подключаем все:
переписка в Telegram, закрытые чаты, расшифровки созвонов, CRM и чужие базы, которые тебе передали.

3 стадии:
(1) скан базы — sobrat (кто есть: теплота, язык, формат — без модели) или iz_vygruzki (та же личка из сохранённой
    выгрузки, когда Telegram недоступен), rasshifrovki (с кем были созвоны — по расшифровкам Zoom и записей),
    деловые поля карточки (zapolnit) и технические поля — ссылки на то, что уже лежит у владельца (istochnik);
    плотное заполнение — ochered (кто с созвонами не заполнен) → pachka (его речь и сообщения в одном файле) →
    zapolnit --fayl (карточки пачкой), isklyuchit (не соцактив), socaktiv (таблица без имён), utechki (проверка);
(2) под продукт — produkt регистрирует продукт с интро, pod_produkt даёт кандидатов, ocenit — оценка ИИ, celevye — итог;
(3) под группу — тот же блок стадии 2, только продукт участника группы; vneshnyaya — внешняя таблица ему.
У каждого значения — состояние: факт (слова самого человека) · со слов передавшего · гипотеза ИИ — и дата сведений.
Чужая база: import_bazy (его формат → наши поля, всё «со слов передавшего») → dlya_partnera (копия ему на разметку)
→ razmetka (кто к нему прислушается и как он нас представит). «Не берусь — не трогать» исключает человека из выборок.

Работает через уже подключённый Telegram (скил podklyuchit-telegram): та же сессия и тот же .env,
по умолчанию в соседней папке connections/telegram. Только чтение — никому не пишет.
Всё хранится локально в private/indeks.sqlite. Наружу — только внешняя таблица без имён и контактов.
"""
import argparse
import asyncio
import csv
import json
from datetime import date, datetime, timedelta, timezone
import os
from pathlib import Path
import re
import sqlite3
import statistics

ROOT = Path(__file__).resolve().parent
DB = Path(os.environ.get("INDEKS_DB", ROOT / "private" / "indeks.sqlite"))
TG = Path(os.environ.get("TELEGRAM_DIR", ROOT.parent / "telegram"))

SCHEMA = """
create table if not exists people(id integer primary key, name text, username text, last_id integer default 0,
  msgs integer default 0, first_at text, last_at text, last_out integer, zvonki integer default 0,
  teplota text, stil text, kompaniya text, rol text, chem_polezen text, zametki text, updated_at text);
create table if not exists msgs(chat_id integer, id integer, date text, out integer, dlina integer,
  golos integer, tekst text, primary key(chat_id, id));
create table if not exists istochniki(chat_id integer, tip text, ssylka text, opisanie text, added_at text,
  primary key(chat_id, ssylka));
create table if not exists chat_msgs(user_id integer, chat text, soobshcheniy integer, obrazec text,
  primary key(user_id, chat));
create table if not exists sostoyaniya(chat_id integer, pole text, sost text, data text, primary key(chat_id, pole));
create table if not exists produkty(kod text primary key, nazvanie text, chey text, lider text, intro text);
create table if not exists pod_produkt(chat_id integer, produkt text, kandidat text, pochemu text, segment text,
  status text, partner text, kakie text, balans text, kommenty text, zachem text, sost text, data text,
  primary key(chat_id, produkt));
create table if not exists razmetka(chat_id integer, vladelec text, prislushaetsya integer, dostup text, data text,
  primary key(chat_id, vladelec));
"""
# Деловые поля карточки (стадия 1), их пишет ИИ. resursy — «у него: ресурсы и выходы», kto_nuzhen — «запросы».
DELOVYE = ("profil", "napravlenie", "keysy", "masshtab", "resursy", "kto_nuzhen", "svyaz", "ton")
# Считает сама механика, без модели: язык и формат сообщения, на который человек отвечает.
MEHANIKA = ("yazyk", "format")
# Старые базы получают новые колонки через alter table в db(), без пересборки.
TEKST_KOLONKI = DELOVYE + MEHANIKA + ("data_svedeniy", "vladelec", "isklyuchen", "posl_zvonok")  # isklyuchen — почему не соцактив
CHISLO_KOLONKI = ("interes", "ne_trogat", "sozvony")  # sozvony — созвоны по расшифровкам
METKI = {"kompaniya": "Компания", "rol": "Должность", "napravlenie": "Направление — что делает и для кого",
         "keysy": "Кейсы", "masshtab": "Масштаб", "resursy": "У него — ресурсы и выходы",
         "kto_nuzhen": "Запросы — что и кто ему нужен", "chem_polezen": "Чем полезен", "teplota": "Теплота",
         "stil": "Как общается", "yazyk": "Язык", "format": "Формат", "ton": "Тон", "data_svedeniy": "Дата обновления"}
# Внешняя база по умолчанию — компания, должность и 5 пунктов интро: оффер и для кого, кейсы, кто нужен, что даёт взамен.
VNESHNIE = ["kompaniya", "rol", "napravlenie", "keysy", "kto_nuzhen", "resursy"]
# Наружу не уходят никогда: по ним человека узнают или находят в обход владельца.
ZAPRET_NARUZHU = {"name", "username", "profil", "svyaz", "zametki", "istochniki", "vladelec"}
# Состояние значения: слова самого человека · то, что лежит в чужой базе или сказал её владелец · вывод ИИ.
SOST = {"факт": "факт", "передавший": "со слов передавшего", "гипотеза": "гипотеза"}
ZNAK = {"факт": "●", "со слов передавшего": "◐", "гипотеза": "○"}
PARTNERY = ("маяк", "джокер", "связной")  # маяк — у него твои клиенты; джокер — твои маяки; связной — твои джокеры
SEGMENTY = ("A", "B", "C")  # A — много денег, мало заморочек · B — заморочки с деньгами · C — заморочки без денег
DOSTUP = ("пролоббирую и сопровожу сделку", "представлю лично на встрече", "познакомлю в переписке",
          "не берусь — прорабатывайте сами", "не берусь — не трогать")
# Колонки чужой таблицы → наши поля. Сравнение по началу слова, без регистра; не узнали — в заметки, ничего не теряем.
SINONIMY = {"name": ("имя", "фио", "name"), "kompaniya": ("компан", "company", "организац"),
            "rol": ("должност", "position", "title", "роль"), "username": ("telegram", "телеграм", "тг", "tg", "ник", "username"),
            "napravlenie": ("направлен", "чем занимается", "деятельност", "описани", "оффер"), "keysy": ("кейс",),
            "masshtab": ("масштаб", "выручк", "оборот"), "resursy": ("ресурс", "выход"), "kto_nuzhen": ("запрос", "ищет", "нужн"),
            "profil": ("профил", "ссылк", "linkedin", "сайт"), "data_svedeniy": ("дата", "обновл"),
            "zametki": ("заметк", "коммент", "примечан")}
TY = re.compile(r"\b(ты|тебе|тебя|тобой|твой|твоя|твоё|твои)\b", re.I)
VY = re.compile(r"\b(вы|вам|вас|вами|ваш|ваша|ваше|ваши)\b", re.I)
EMOJI = re.compile("[\U0001F300-\U0001FAFF☀-➿]")
STOP = set("который которые которая также чтобы через между после перед более менее очень может можно нужно этого этой этих".split())


def db():
    DB.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(DB)
    c.executescript(SCHEMA)
    est = {r[1] for r in c.execute("pragma table_info(people)")}
    for pole in TEKST_KOLONKI + CHISLO_KOLONKI:
        if pole not in est:
            c.execute(f"alter table people add column {pole} {'integer' if pole in CHISLO_KOLONKI else 'text'}")
    return c


def segodnya():
    return date.today().isoformat()


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


def yazyk(rows):
    """На каком языке человек пишет — по буквам его сообщений, без ссылок и ников."""
    ego = " ".join(re.sub(r"(https?://|@)\S+", "", r[4] or "") for r in rows if not r[1])
    kir = len(re.findall(r"[а-яёіїєґ]", ego, re.I))
    lat = len(re.findall(r"[a-z]", ego, re.I))
    if kir + lat < 20:
        return "не ясно"
    if kir >= 0.8 * (kir + lat):
        return "украинский" if len(re.findall(r"[іїєґ]", ego, re.I)) > 0.02 * kir else "русский"
    if lat >= 0.8 * (kir + lat):
        return "английский"
    return "русский и английский"


def serii(rows):
    """Сколько сообщений подряд человек обычно шлёт (пауза до 3 минут) — пишет серией или одним."""
    razmery, tek, prev = [], 0, None
    for r in rows:
        t = datetime.fromisoformat(r[0])
        if r[1]:
            if tek:
                razmery.append(tek)
            tek, prev = 0, None
            continue
        if tek and prev and (t - prev).total_seconds() <= 180:
            tek += 1
        else:
            if tek:
                razmery.append(tek)
            tek = 1
        prev = t
    if tek:
        razmery.append(tek)
    return statistics.median(razmery) if razmery else 0


def format_soobshcheniya(rows):
    """Формат, в котором человеку писать, чтобы ответил: длина по его же сообщениям, серия или одно, абзацы, голос.
    Длина — 75-й процентиль его текстов, вверх до 50 знаков: так пишет он сам, длиннее он не дочитывает."""
    ego = [r for r in rows if not r[1]]
    teksty = sorted(r[2] for r in ego if not r[3] and r[2])
    if not teksty:
        return "мало текста — пиши коротко"
    p75 = teksty[min(len(teksty) - 1, int(len(teksty) * 0.75))]
    chasti = [f"до ~{max(50, -(-p75 // 50) * 50)} знаков"]
    s = serii(rows)
    chasti.append(f"серией из {round(s)} коротких" if s >= 2 else "одним сообщением")
    dlinnye = [r for r in ego if (r[2] or 0) > 150]
    if dlinnye and sum("\n" in (r[4] or "") for r in dlinnye) / len(dlinnye) >= 0.3:
        chasti.append("с абзацами или списком")
    if sum(r[3] for r in ego) / len(ego) >= 0.2:
        chasti.append("голосовое тоже ок")
    return " · ".join(chasti)


def teplota(last_at, last_out, zvonki, msgs, now=None):
    """Горячий — созванивались (звонок в Telegram или созвон по расшифровке) или переписка от 200 сообщений;
    тёплый — живой диалог за 30 дней;
    иначе «оживить» — сначала напомнить о себе, в верхнюю пятёрку подборки не ставить."""
    now = now or datetime.now(timezone.utc)
    if zvonki or msgs >= 200:
        return "горячий"
    if last_at and now - datetime.fromisoformat(last_at) <= timedelta(days=30):
        return "тёплый"
    return "оживить"


def obnovit_kartochku(c, pid):
    rows = c.execute("select date, out, dlina, golos, tekst from msgs where chat_id=? order by date", (pid,)).fetchall()
    p = c.execute("select last_at, last_out, zvonki + coalesce(sozvony, 0), msgs from people where id=?", (pid,)).fetchone()
    c.execute("update people set stil=?, teplota=?, yazyk=?, format=?, updated_at=? where id=?",
              (stil(rows), teplota(*p), yazyk(rows), format_soobshcheniya(rows), datetime.now(timezone.utc).isoformat(), pid))


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
                    c.execute("update people set zvonki=zvonki+1, posl_zvonok=max(coalesce(posl_zvonok, ''), ?) "
                              "where id=?", (m.date.isoformat()[:10], e.id))
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


def iz_vygruzki(c, papka, minimum=5, imena=None):
    """Стадия 1 без Telegram: личка из сохранённой выгрузки. Один файл <id>.jsonl — один диалог, строка — сообщение:
    {"id": 1, "d": "ГГГГ-ММ-ДД ЧЧ:ММ" (UTC), "ya": 1 — моё | "on": 1 — его, "t": текст, "golos_sek", "zvonok_sek"}.
    imena — JSON {id: {"imya"|"name", "nik"|"username"}}, иначе имя = id. Уже собранное не читаем: только новее last_id."""
    imena = imena or {}
    lyudey = novyh = 0
    for f in sorted(Path(papka).glob("*.jsonl")):
        if not f.stem.lstrip("-").isdigit():
            continue
        pid = int(f.stem)
        im = imena.get(f.stem) or imena.get(pid) or {}
        row = c.execute("select last_id from people where id=?", (pid,)).fetchone()
        if row is None:
            c.execute("insert into people(id, name, username) values(?,?,?)",
                      (pid, im.get("imya") or im.get("name") or f.stem, (im.get("nik") or im.get("username") or None)))
        last_id = row[0] if row else 0
        prishlo = 0
        for stroka in open(f, encoding="utf-8"):
            try:
                m = json.loads(stroka)
            except ValueError:
                continue
            if not isinstance(m.get("id"), int) or m["id"] <= last_id or not m.get("d"):
                continue
            d = datetime.strptime(m["d"][:16], "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc).isoformat()
            if m.get("zvonok_sek"):
                c.execute("update people set zvonki=zvonki+1, last_id=max(last_id, ?), "
                          "posl_zvonok=max(coalesce(posl_zvonok, ''), ?) where id=?", (m["id"], m["d"][:10], pid))
                continue
            out = 1 if m.get("ya") else 0
            t = m.get("t") or ""
            c.execute("insert or ignore into msgs values(?,?,?,?,?,?,?)",
                      (pid, m["id"], d, out, len(t), int(bool(m.get("golos_sek"))), t[:500]))
            c.execute("update people set last_id=max(last_id, ?), msgs=msgs+1, first_at=coalesce(first_at, ?), "
                      "last_at=?, last_out=? where id=?", (m["id"], d, d, out, pid))
            prishlo += 1
        if c.execute("select msgs from people where id=?", (pid,)).fetchone()[0] < minimum:
            continue
        if prishlo:
            obnovit_kartochku(c, pid)
            novyh += prishlo
        lyudey += 1
        c.execute("insert or ignore into istochniki values(?,?,?,?,?)",
                  (pid, "сохранённая переписка", str(f), "", datetime.now(timezone.utc).isoformat()))
        c.commit()
    c.commit()
    return lyudey, novyh


# Кто говорит в строке расшифровки: «Имя Фамилия: …», «[12:34] Имя: …», «Имя @ник (Компания): …», «Имя (Speaker 2): …»
SPIKER = re.compile(r"^\s*(?:\[?\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d+)?\]?\s*[-–—]?\s*)?([^:\n]{2,90}?):\s")
NIK = re.compile(r"@([A-Za-z][A-Za-z0-9_]{3,31})")


def tokeny(s):
    return [w for w in re.findall(r"[a-zа-я]+", (s or "").lower().replace("ё", "е")) if len(w) > 1]


def spikery(tekst):
    """Говорящие в расшифровке: {метка: (ник или None, токены имени, реплик)}. Без ника — только имя из 2–3 слов
    с заглавной буквы, чтобы «Например: …» не стал человеком."""
    out = {}
    for line in tekst.splitlines():
        if "-->" in line:
            continue
        mm = SPIKER.match(line)
        if not mm:
            continue
        metka = mm.group(1).strip()
        if "http" in metka or len(metka.split()) > 7:
            continue
        nik = NIK.search(metka)
        imya_ch = re.split(r"[@(]", metka)[0].strip()
        slova_ = imya_ch.split()
        if not nik and not (2 <= len(slova_) <= 3 and all(w[:1].isupper() for w in slova_)):
            continue
        z = out.setdefault(metka, [nik.group(1).lower() if nik else None, tokeny(imya_ch), 0])
        z[2] += 1
    return out


TRANSLIT = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
                    ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "i", "k", "l", "m", "n", "o", "p", "r", "s", "t",
                     "u", "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]))
# Полное имя ← уменьшительные и латиница: «Дима», «Dmitry» и «Дмитрий» — один человек
IMENA = {"дмитрий": "дима митя dmitry dmitriy dima", "александр": "саша шура alexander aleksandr alex sasha",
         "александра": "саша alexandra", "алексей": "леша лёша alexey aleksey alexei", "анастасия": "настя anastasia nastya",
         "анна": "аня anna anya", "андрей": "andrey andrei", "антон": "антоша anton", "владимир": "вова володя vladimir",
         "дарья": "даша darya daria", "денис": "denis", "евгений": "женя evgeny evgeniy zhenya", "евгения": "женя evgenia",
         "екатерина": "катя ekaterina katya", "елена": "лена elena lena", "иван": "ваня ivan", "ирина": "ира irina",
         "константин": "костя konstantin kostya", "ксения": "ксюша kseniya ksenia", "мария": "маша maria mariya masha",
         "михаил": "миша mikhail michael misha", "наталья": "наталия наташа natalia natalya", "николай": "коля nikolay",
         "ольга": "оля olga", "павел": "паша pavel pasha", "роман": "рома roman", "светлана": "света svetlana",
         "сергей": "серёжа сережа sergey sergei", "татьяна": "таня tatiana tatyana tanya", "юлия": "юля yulia julia",
         "ярослав": "слава yaroslav", "максим": "макс maxim maksim", "илья": "ilya", "олег": "oleg", "игорь": "igor",
         "виталий": "vitaly vitaliy", "станислав": "стас stanislav", "вячеслав": "слава vyacheslav", "артём": "артем artem"}
NE_LYUDI = {"пользователь zoom", "zoom user", "iphone", "ipad", "speaker", "участник", "гость", "guest"}


def skelet(w):
    """Скелет слова для сравнения написаний: кириллица → латиница, похожие сочетания склеены."""
    w = "".join(TRANSLIT.get(ch, ch) for ch in w.lower())
    for a, b in (("kh", "h"), ("tc", "c"), ("ts", "c"), ("cz", "c"), ("ks", "x"), ("ph", "f"), ("w", "v"),
                 ("j", "i"), ("y", "i"), ("ii", "i"), ("ie", "e"), ("ye", "e")):
        w = w.replace(a, b)
    return re.sub(r"(.)\1+", r"\1", w)


KANON = {}
for _polnoe, _var in IMENA.items():
    for _v in [_polnoe] + _var.split():
        KANON[skelet(_v)] = _polnoe


def imya_kanon(w):
    return KANON.get(skelet(w))


def indeks_imen(c):
    """Для поиска по фамилии: скелет слова → [(id, скелеты слов имени, канонические имена)]."""
    idx = {}
    for i, name in c.execute("select id, name from people"):
        tk = tokeny(name)
        sk = {skelet(w) for w in tk}
        kan = {imya_kanon(w) for w in tk} - {None}
        for w in sk:
            idx.setdefault(w, []).append((i, sk, kan))
    return idx


def po_imeni(idx, tk):
    """Один человек по имени из расшифровки или None. Фамилия (не имя) — по скелету, имя — по канону:
    «Dmitry Sudakov» = «Дмитрий Судаков» = «Дима Судаков». Два и больше совпадений — не угадываем."""
    familii = [skelet(w) for w in tk if imya_kanon(w) is None]
    if not familii:
        return None

    def nashlos(w, sk, kan):  # слово из расшифровки есть у человека: тем же написанием или тем же полным именем
        return skelet(w) in sk or (imya_kanon(w) is not None and imya_kanon(w) in kan)

    kand = {i for i, sk, kan in idx.get(familii[0], []) if all(nashlos(w, sk, kan) for w in tk)}
    return kand.pop() if len(kand) == 1 else None


def rasshifrovki(c, papka, ya=(), novye=False):
    """Стадия 1: с кем были созвоны — по расшифровкам (.vtt, .txt, .md) в папке и подпапках.
    Говорящий находится по нику в метке («Имя @ник (Компания)») или по имени из 2–3 слов, если в базе ровно одно
    совпадение. Каждый созвон — источник «созвон» и +1 к sozvony: такой человек горячий.
    Нет в базе, но в метке есть ник — новая карточка «из созвона». Без ника и без совпадения — в отчёт «не опознаны»;
    novye=True заводит карточку и по имени. ya — твои имена и ники: себя не считаем."""
    ya_nik = {x.lstrip("@").lower() for x in ya if x.startswith("@")}
    ya_imena = [set(tokeny(x)) for x in ya if not x.startswith("@")]
    po_niku = {u.lower(): i for i, u in c.execute("select id, username from people where username is not null")}
    po_slovu = {}
    for i, name in c.execute("select id, name from people"):
        tk = set(tokeny(name))
        for w in tk:
            po_slovu.setdefault(w, []).append((i, tk))
    idx = indeks_imen(c)
    faylov = svyazey = novyh = 0
    neopoznany, tronuty = {}, set()
    for f in sorted(p for p in Path(papka).rglob("*") if p.suffix.lower() in (".vtt", ".txt", ".md")):
        try:
            sp = spikery(f.read_text(encoding="utf-8", errors="ignore"))
        except OSError:
            continue
        if not sp:
            continue
        faylov += 1
        dm = re.search(r"(\d{4})-(\d{2})-(\d{2})", f.name)
        data = "-".join(dm.groups()) if dm else datetime.fromtimestamp(f.stat().st_mtime).date().isoformat()
        for metka, (nik, tk, n) in sp.items():
            if (nik and nik in ya_nik) or any(y and y <= set(tk) for y in ya_imena) \
                    or " ".join(tk) in NE_LYUDI or (tk and tk[0] in NE_LYUDI):
                continue
            pid = po_niku.get(nik) if nik else None
            if pid is None and len(tk) >= 2:
                kand = {i for i, ptk in po_slovu.get(tk[0], []) if set(tk) <= ptk}
                pid = kand.pop() if len(kand) == 1 else po_imeni(idx, tk)
            if pid is None and (nik or (novye and len(tk) >= 2)):
                pid = min(0, c.execute("select min(id) from people").fetchone()[0] or 0) - 1
                imya_ch = re.split(r"[@(]", metka)[0].strip() or metka
                c.execute("insert into people(id, name, username, teplota) values(?,?,?,?)", (pid, imya_ch, nik, "горячий"))
                if nik:
                    po_niku[nik] = pid
                for w in tk:
                    po_slovu.setdefault(w, []).append((pid, set(tk)))
                    idx.setdefault(skelet(w), []).append((pid, {skelet(x) for x in tk}, {imya_kanon(x) for x in tk} - {None}))
                novyh += 1
            if pid is None:
                neopoznany[metka] = neopoznany.get(metka, 0) + 1
                continue
            r = c.execute("insert or ignore into istochniki values(?,?,?,?,?)",
                          (pid, "созвон", str(f), f"созвон {data}, реплик {n}", datetime.now(timezone.utc).isoformat()))
            if r.rowcount:
                c.execute("update people set sozvony=coalesce(sozvony, 0)+1 where id=?", (pid,))
                svyazey += 1
                tronuty.add(pid)
    for pid in tronuty:
        obnovit_kartochku(c, pid)
    c.commit()
    top = sorted(neopoznany.items(), key=lambda x: -x[1])
    return faylov, svyazey, novyh, top


def slova(tekst):
    return {w for w in re.findall(r"[a-zа-яё0-9]{4,}", tekst.lower()) if w not in STOP}


def sovpadeniya(c, zapros, top):
    """Совпадения текста с карточками. Текст — интро продукта: 5 пунктов разговора, слайд или упаковка;
    чем подробнее, тем больше ключей и точнее выбор. Холодный без «интересно самому» и «не трогать» — не идут."""
    klyuchi = {w[:6] for w in slova(zapros)}
    out = []
    c.row_factory = sqlite3.Row
    for r in c.execute("select * from people"):
        if (r["teplota"] == "холодный" and not r["interes"]) or r["ne_trogat"] or r["isklyuchen"]:
            continue
        tekst = " ".join(r[k] or "" for k in ("kompaniya", "rol", "chem_polezen", "zametki", "napravlenie",
                                             "keysy", "masshtab", "resursy", "kto_nuzhen")).lower()
        hit = sorted({k for k in klyuchi if k in tekst})
        if hit:
            out.append((len(hit) + (r["teplota"] == "горячий") * 0.5 + (r["teplota"] == "тёплый") * 0.25, dict(r), hit))
    c.row_factory = None
    out.sort(key=lambda x: -x[0])
    return out[:top]


def vneshnie_polya(polya=None):
    """Поля внешней таблицы: по умолчанию компания, должность и 5 пунктов интро; запрещённые — отказ."""
    polya = [p.strip() for p in polya.split(",")] if isinstance(polya, str) else (polya or VNESHNIE)
    if bad := [p for p in polya if p in ZAPRET_NARUZHU]:
        raise SystemExit(f"Наружу не отдаём: {', '.join(bad)} — по ним человека узнают. Это поля внутренней базы.")
    if bad := [p for p in polya if p not in METKI]:
        raise SystemExit(f"Нет таких полей: {', '.join(bad)}. Есть: {', '.join(METKI)}")
    return polya


def zapisat(rows, put, s_imenami, polya=None, istochniki=None):
    """s_imenami — внутренняя таблица владельца: все поля, связь и источники. Иначе — внешняя, только polya."""
    put.parent.mkdir(parents=True, exist_ok=True)
    polya = list(METKI) if s_imenami else vneshnie_polya(polya)
    with open(put, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow((["Код", "Имя", "Ник", "Профиль", "Связь", "Заметки", "Источники", "Владелец контакта"] if s_imenami else [])
                   + [METKI[p] for p in polya] + ["Совпало по"])
        for _, r, hit in rows:
            vnutr = [r["id"], r["name"], r["username"] or "", r["profil"] or "", r["svyaz"] or "", r["zametki"] or "",
                     (istochniki or {}).get(r["id"], ""), r.get("vladelec") or "мой"]
            znach = [r.get(p) or "" for p in polya] if s_imenami else [bez_imen(r.get(p)) for p in polya]
            w.writerow((vnutr if s_imenami else []) + znach + [", ".join(hit)])
    return put


def otmetit(c, pid, polya, sost, data):
    """Состояние и дата для каждого заполненного поля: факт · со слов передавшего · гипотеза."""
    for p in polya:
        c.execute("insert or replace into sostoyaniya values(?,?,?,?)", (pid, p, sost, data))
    if polya:
        c.execute("update people set data_svedeniy=? where id=?", (data, pid))


# Плотное заполнение (25.10.2026): кого заполнять по созвонам, пачка материала для ИИ, карточки пачкой,
# исключения «не соцактив», таблица соцактива без имён и проверка исходящей таблицы на утечки.
GOTOVO = ("заполнено по расшифровке", "заполнено по источникам")
POLYA_KARTOCHKI = ("profil", "kompaniya", "rol", "napravlenie", "keysy", "masshtab", "resursy", "kto_nuzhen", "svyaz", "ton")
# Фразы с делом: цифры, клиенты, кого ищет. По ним из длинной речи берём то, что нужно карточке.
DELO = re.compile(r"(зову|занима|компани|бизнес|выручк|оборот|клиент|продаж|ищу|ищем|нужн|интерес|миллион|млн|млрд|тысяч|"
                  r"процент|партн|работаем|делаем|производ|проект|рынок|сегмент|аудитор|команд|сотрудник|кейс|запуст|"
                  r"сервис|платформ|продукт|завод|инвест|фонд|акселер|директор|основател|руковод|сделк|чек|лид)", re.I)


def data_iz_puti(put):
    m = re.search(r"(20\d\d)-(\d\d)-(\d\d)", str(put))
    return "-".join(m.groups()) if m else ""


def posledniy_sozvon(c, pid):
    """Последний созвон: дата из расшифровки или последний звонок в Telegram."""
    daty = [data_iz_puti(op) or data_iz_puti(s) for s, op in
            c.execute("select ssylka, opisanie from istochniki where chat_id=? and tip='созвон'", (pid,))]
    r = c.execute("select posl_zvonok from people where id=?", (pid,)).fetchone()
    return max([d for d in daty if d] + [(r and r[0]) or ""])


def ego_repliki(put, pid, name, un):
    """Его реплики в расшифровке: метка с его ником или его имя — с транслитом и уменьшительными. → (метка, речь)."""
    try:
        tekst = Path(put).read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return "", ""
    tk = tokeny(name)
    sk = {skelet(w) for w in tk}
    kan = {imya_kanon(w) for w in tk} - {None}
    idx = {w: [(pid, sk, kan)] for w in sk}
    moi = {m for m, (nik, t, n) in spikery(tekst).items() if (un and nik == un.lower()) or po_imeni(idx, t) == pid}
    rech = []
    for line in tekst.splitlines():
        mm = SPIKER.match(line)
        if mm and mm.group(1).strip() in moi:
            rech.append(line[mm.end():].strip())
    return (sorted(moi)[0] if moi else ""), " ".join(rech)


def vyzhimka(rech, znakov):
    """Начало рассказа — там он представляется — и фразы с делом, в исходном порядке."""
    nachalo = rech[:700]
    vzyato, dlina = [], len(nachalo)
    for f in (f.strip() for f in re.split(r"(?<=[.?!])\s+", rech)):
        if len(f) > 25 and DELO.search(f) and f not in nachalo:
            vzyato.append(f)
            dlina += len(f) + 1
            if dlina >= znakov:
                break
    return nachalo + (" … " + " ".join(vzyato) if vzyato else "")


def ochered(c):
    """Кого заполнять плотно: все, с кем был созвон, кроме исключённых, «не трогать» и уже заполненных.
    Сначала те, у кого есть расшифровка, внутри — свежие созвоны сверху."""
    rows = []
    for pid, name, un in c.execute("select id, name, username from people where (coalesce(sozvony,0)>0 or zvonki>0) "
                                   "and isklyuchen is null and coalesce(ne_trogat, 0)=0"):
        if c.execute(f"select 1 from istochniki where chat_id=? and tip in ({','.join('?' * len(GOTOVO))})",
                     (pid, *GOTOVO)).fetchone():
            continue
        puti = [s for (s,) in c.execute("select ssylka from istochniki where chat_id=? and tip='созвон'", (pid,))]
        rows.append((0 if puti else 1, posledniy_sozvon(c, pid), pid, name, un, puti))
    rows.sort(key=lambda r: (r[0], -int((r[1] or "0").replace("-", ""))))
    return rows


def pachka(c, n=30, rech=1300, dop=None):
    """Материал на n человек из очереди — всё по человеку в одном месте: что уже в карточке, его речь из расшифровок,
    его сообщения в личке с делом и цифрами. dop(pid) → строки из твоих дополнительных источников.
    ИИ читает и пишет карточки в JSON для zapolnit --fayl. → (текст, людей, осталось после пачки)."""
    q = ochered(c)
    L = []
    for _, posl, pid, name, un, puti in q[:n]:
        r = c.execute("select kompaniya, rol, napravlenie, keysy, masshtab, resursy, kto_nuzhen, msgs from people where id=?",
                      (pid,)).fetchone()
        L.append(f"## {pid} · {name} · @{un or '—'} · последний созвон {posl or '—'} · сообщений в личке {r[7] or 0}")
        L.append("Карточка: " + (" | ".join(f"{k}: {v[:200]}" for k, v in zip(
            ("компания", "роль", "направление", "кейсы", "масштаб", "ресурсы", "запросы"), r[:7]) if v) or "пусто"))
        L += list(dop(pid) if dop else [])
        osn = {p.replace("_companion", "") for p in puti}  # копия Zoom рядом с основной расшифровкой — не читаем дважды
        puti = [p for p in puti if "_companion" not in p or p.replace("_companion", "") not in osn]
        rechi = sorted([(p, *ego_repliki(p, pid, name, un)) for p in puti], key=lambda x: -len(x[2]))[:2]
        for p, metka, rr in rechi:
            if rr:
                L.append(f"Речь {data_iz_puti(p) or 'без даты'} «{metka}»: " + vyzhimka(rr, rech // max(1, len(rechi))))
        ego = [(d[:10], t) for d, t in c.execute("select date, tekst from msgs where chat_id=? and out=0 and length(tekst)>40",
                                                 (pid,))]
        ego = sorted(ego, key=lambda x: -(len(x[1]) + 400 * bool(DELO.search(x[1]))))
        vybor, dl = [], 0
        for d, t in ego:
            if dl >= 900:
                break
            vybor.append((d, t[:380]))
            dl += len(t[:380])
        if vybor:
            L.append("Его в личке: " + " | ".join(f"[{d}] {t}" for d, t in sorted(vybor)))
        L.append("")
    return "\n".join(L), len(q[:n]), len(q) - len(q[:n])


def isklyuchit(c, pid, pochemu):
    """Не соцактив: личное, своя команда, второй аккаунт. Выпадает из очереди, соцактива, pustye и совпадений."""
    c.execute("update people set isklyuchen=? where id=?", (pochemu or None, pid))


def zapolnit_pachkoy(c, kartochki):
    """Карточки пачкой: [{"id"|"kto", "data", "otkuda", поля…, "gipoteza": [поля-выводы], "isklyuchit": "почему"}].
    Поле — его слова (● факт), если не названо в gipoteza (○). Источник «заполнено по …» снимает человека с очереди.
    → (заполнено, исключено, нет в индексе)."""
    gotovo = isk = 0
    net = []
    for k in kartochki:
        kto = str(k.get("id", k.get("kto", ""))).lstrip("@")
        r = c.execute("select id from people where id=? or lower(username)=lower(?)",
                      (int(kto) if kto.lstrip("-").isdigit() else 0, kto)).fetchone()
        if not r:
            net.append(kto)
            continue
        pid, data = r[0], k.get("data") or segodnya()
        if k.get("isklyuchit"):
            isklyuchit(c, pid, k["isklyuchit"])
            isk += 1
        est = [p for p in POLYA_KARTOCHKI if k.get(p)]
        for p in est:
            c.execute(f"update people set {p}=? where id=?", (k[p], pid))
        gip = set(k.get("gipoteza", []))
        otmetit(c, pid, [p for p in est if p not in gip], SOST["факт"], data)
        otmetit(c, pid, [p for p in est if p in gip], SOST["гипотеза"], data)
        otkuda = k.get("otkuda") or ""
        tip = GOTOVO[0] if re.search(r"расшифр|созвон", otkuda, re.I) else GOTOVO[1]
        c.execute("insert or ignore into istochniki values(?,?,?,?,?)",
                  (pid, tip, otkuda or "карточка пачкой", f"поля: {', '.join(est) or 'деловых фактов нет'}",
                   datetime.now(timezone.utc).isoformat()))
        gotovo += 1
    c.commit()
    return gotovo, isk, net


ZAGLUSHKA = re.compile(r"(не выделен|не восстановлен|требу\w* уточнени|не назван|не указан|не раскрыт|^—$|^true$)", re.I)
_IMENA_RE = None


def bez_imen(t):
    """Текст наружу без имён людей: @ники, ссылки, почты, телефоны — прочь; имя с фамилией, «Фамилия Имя» и известные
    имена — «[имя]». Компании и бренды остаются. Заглушки вида «не выделено» — пусто."""
    global _IMENA_RE
    if not t or (ZAGLUSHKA.search(t) and len(t) < 100):
        return ""
    if _IMENA_RE is None:
        vse = {v.capitalize() for polnoe, var in IMENA.items() for v in [polnoe] + var.split()}
        fam = r"[А-ЯЁ][а-яё]+(?:ов|ев|ёв|ин|ын|ова|ева|ёва|ина|ына|ский|ская|енко)\s+"
        _IMENA_RE = re.compile(r"\b(?:" + fam + r")?(?:" + "|".join(sorted(vse, key=len, reverse=True))
                               + r")(?:\s+[А-ЯЁA-Z][а-яёa-z-]+)?\b")
    t = re.sub(r"\b[\w.+-]+@[\w-]+\.[\w.]+", "", t)
    t = re.sub(r"@\w{3,}", "", t)
    t = re.sub(r"https?://\S+|t\.me/\S+|www\.\S+", "", t)
    t = re.sub(r"(?:\+7|\b8)[\s(-]*\d{3}[\s)-]*\d{3}[\s-]*\d{2}[\s-]*\d{2}\b", "", t)
    t = _IMENA_RE.sub("[имя]", t)
    okonch = r"(?:ов|ев|ёв|ин|ын|ий|ой|ова|ева|ина|ына|ская|ский|ко|ук|юк|ич|ян)"
    t = re.sub(r"\b[А-ЯЁ][а-яё]{2,}\s+[А-ЯЁ][а-яё]{2,}" + okonch + r"\b", "[имя]", t)  # «Имя Фамилия»
    t = re.sub(r"\b[А-ЯЁ][а-яё]{2,}(?:ов|ев|ёв|ин|ын|ова|ева|ина|ына|ская|ский|енко)\s+[А-ЯЁ][а-яё]{2,}\b", "[имя]", t)
    return re.sub(r"\s{2,}", " ", t).strip(" ;,·")


SOCAKTIV = ["№", "Компания и должность", "Направление — что делает и для кого", "Кейсы и масштаб",
            "У него — ресурсы и выходы", "Запросы — что и кто ему нужен", "Дата обновления", "Теплота", "Последний созвон"]


def socaktiv(c, dney=None, vse=False):
    """Текущий соцактив — поля стадии 1 без полей с замком (имя, ник, профиль, связь — только у тебя), со знаком
    состояния. По умолчанию — все, с кем был созвон; vse — все с деловыми полями; dney — созвон не старше N дней.
    Свежие созвоны сверху. → (строки, без деловых полей — не вошли, ● направление его словами, всего)."""
    sost = {(p, pole): ZNAK.get(s, "") for p, pole, s in c.execute("select chat_id, pole, sost from sostoyaniya")}
    gran = (date.today() - timedelta(days=dney)).isoformat() if dney else ""
    c.row_factory = sqlite3.Row
    usl = "napravlenie is not null or kompaniya is not null" if vse else "coalesce(sozvony,0)>0 or zvonki>0"
    lyudi = c.execute(f"select * from people where ({usl}) and isklyuchen is null").fetchall()
    c.row_factory = None
    rows, pusto = [], 0
    for r in lyudi:
        posl = posledniy_sozvon(c, r["id"])
        if gran and posl < gran:
            continue
        svoe = {w.lower() for w in re.findall(r"[A-Za-zА-Яа-яЁё]{3,}", r["name"] or "")}

        def v(p):
            t = bez_imen(r[p])
            slova_ = {w.lower() for w in re.findall(r"[A-Za-zА-Яа-яЁё]{3,}", t)}
            if p == "kompaniya" and slova_ and slova_ <= svoe:  # в «компанию» иногда попадает его имя из профиля
                t = ""
            return f"{sost.get((r['id'], p), '')} {t}".strip() if t else ""
        komp = " · ".join(x for x in (v("kompaniya"), bez_imen(r["rol"])) if x and x.strip("○◐● ") != "[имя]")
        stroka = [komp, v("napravlenie"), " · ".join(x for x in (v("keysy"), v("masshtab")) if x), v("resursy"),
                  v("kto_nuzhen"), r["data_svedeniy"] or "", r["teplota"] or "", posl or "—"]
        if stroka[0] or stroka[1]:
            rows.append(stroka)
        else:
            pusto += 1
    rows.sort(key=lambda x: -int((x[7] if x[7][:2] == "20" else "0").replace("-", "")))
    return rows, pusto, sum(1 for x in rows if x[1].startswith("●")), len(rows) + pusto


# Фамилия по окончанию — кириллицей и латиницей. «Сколково», «Авито», «Маркетинг» из подписей в профиле — не фамилии.
FAMILIYA = re.compile(r"(ов|ев|ёв|ин|ын|ова|ева|ёва|ина|ына|ский|ская|цкий|цкая|енко|ук|юк|ич|ян|дзе|швили|ov|ev|in|ova|eva|ina|sky|skiy|skaya|enko|yan)$")


def utechki(c, stroki_):
    """Проверка исходящей таблицы: ники, ссылки, почты, телефоны, длинные номера и фамилии людей из индекса.
    → [(строка, что, найдено)]. Фамилия, совпавшая с брендом, — смотри глазами: бренды наружу можно."""
    fam = set()
    for (name,) in c.execute("select name from people where name is not null"):
        slova_ = re.findall(r"[А-ЯЁA-Z][а-яёa-z]{3,}", name)
        if len(slova_) >= 2 and any(imya_kanon(w) for w in slova_):  # в имени есть имя — рядом ищем фамилию
            fam |= {w for w in slova_ if not imya_kanon(w) and FAMILIYA.search(w)}
    shabl = {"ник": r"@\w{3,}", "ссылка": r"https?://|t\.me/|www\.", "почта": r"\b[\w.+-]+@[\w-]+\.\w+",
             "телефон": r"(?:\+7|\b8)[\s(-]*\d{3}[\s)-]*\d{3}[\s-]*\d{2}[\s-]*\d{2}\b", "длинный номер": r"\b\d{8,}\b",
             "имя с фамилией": r"\b(?:" + "|".join(sorted({v.capitalize() for p_, var in IMENA.items()
                                                            for v in [p_] + var.split()}, key=len, reverse=True))
                               + r")\s+[А-ЯЁ][а-яё]{2,}(?:ов|ев|ин|ова|ева|ина|ский|ская)\b"}
    out = []
    for i, s in enumerate(stroki_, 1):
        t = " | ".join(str(x) for x in s)
        for chto, p in shabl.items():
            out += [(i, chto, m) for m in re.findall(p, t)]
        out += [(i, "фамилия из индекса", w) for w in re.findall(r"\b[А-ЯЁA-Z][а-яёa-z]{3,}\b", t) if w in fam]
    return out


def imya(s):
    return " ".join(x for x in (getattr(s, "first_name", None), getattr(s, "last_name", None)) if x) or "—"


async def iz_chata(client, c, kak, limit, vse=False):
    """Закрытый чат, где владелец состоит → холодные кандидаты: кто писал (сколько и что) и, с --vse, молчащие.
    В совпадения холодный идёт только после отметки «интересно самому» (interes)."""
    kak = kak.lstrip("@").lower()
    chat = None
    async for d in client.iter_dialogs():
        if d.is_user:
            continue
        if kak in (str(d.id), str(getattr(d.entity, "id", "")), (getattr(d.entity, "username", "") or "").lower()) \
                or kak == (d.name or "").lower():
            chat = d
            break
    if chat is None:
        raise SystemExit("Чат не найден: укажи точное название, @ник или id чата, где ты состоишь.")
    nazv = f"чат «{chat.name}»"
    lyudi = {}
    async for m in client.iter_messages(chat.entity, limit=limit):
        s = getattr(m, "sender", None)
        if m.out or s is None or not hasattr(s, "first_name") or getattr(s, "bot", False):
            continue
        z = lyudi.setdefault(s.id, {"s": s, "n": 0, "t": []})
        z["n"] += 1
        if m.message and len(z["t"]) < 3:
            z["t"].append(m.message[:300])
    if vse:
        async for s in client.iter_participants(chat.entity):
            if not getattr(s, "bot", False) and not getattr(s, "is_self", False):
                lyudi.setdefault(s.id, {"s": s, "n": 0, "t": []})
    novyh = 0
    for sid, z in lyudi.items():
        if c.execute("select 1 from people where id=?", (sid,)).fetchone() is None:
            c.execute("insert into people(id, name, username, teplota) values(?,?,?,'холодный')",
                      (sid, imya(z["s"]), getattr(z["s"], "username", None)))
            novyh += 1
        c.execute("insert or replace into chat_msgs values(?,?,?,?)", (sid, nazv, z["n"], " | ".join(z["t"])))
        c.execute("insert or replace into istochniki values(?,?,?,?,?)",
                  (sid, "закрытый чат", nazv, f"{z['n']} сообщений в последних {limit}", datetime.now(timezone.utc).isoformat()))
    c.commit()
    return novyh, len(lyudi)


# ---------- стадии 2 и 3: под продукт (свой или участника группы) ----------

def produkt_ili_stop(c, kod):
    r = c.execute("select kod, nazvanie, chey, lider, intro from produkty where kod=?", (kod,)).fetchone()
    if not r:
        raise SystemExit(f"Продукта «{kod}» нет. Сначала produkt --kod {kod} --nazvanie … --chey мой --intro файл")
    return r


def celevye(c, kod, partner=None):
    c.row_factory = sqlite3.Row
    q = ("select p.*, o.kandidat, o.pochemu, o.segment, o.status, o.partner, o.kakie, o.balans, o.kommenty, o.zachem, "
         "o.sost as osost, o.data as odata from pod_produkt o join people p on p.id=o.chat_id "
         "where o.produkt=? and o.kandidat='да' and coalesce(p.ne_trogat, 0)=0" + (" and o.partner=?" if partner else ""))
    rows = [dict(r) for r in c.execute(q + " order by o.segment is null, o.segment, p.teplota='горячий' desc, "
                                           "p.teplota='тёплый' desc, p.msgs desc", (kod, partner) if partner else (kod,))]
    c.row_factory = None
    return rows


# ---------- чужая база: его формат → наши поля → копия ему на разметку → его разметка ----------

def kolonki_v_polya(zagolovki, karta=None):
    """Заголовки чужой таблицы → поля индекса. Явная карта «Колонка=pole» важнее угадывания."""
    yavno = dict(x.split("=", 1) for x in karta.split(";") if "=" in x) if karta else {}
    out = {}
    for z in zagolovki:
        if z in yavno:
            out[z] = yavno[z].strip()
            continue
        zl = z.strip().lower()
        if "рожд" in zl:  # «дата рождения» — не дата сведений, пусть уйдёт в заметки
            continue
        slova_z = re.split(r"[\s/,()_-]+", zl)
        for pole, sin in SINONIMY.items():
            if any((s in zl) if " " in s else any(w.startswith(s) for w in slova_z) for s in sin) and pole not in out.values():
                out[z] = pole
                break
    return out


def prochitat_tablicu(put):
    put = Path(put)
    if put.suffix.lower() in (".xlsx", ".xlsm"):
        try:
            from openpyxl import load_workbook
        except ImportError:
            raise SystemExit("Для .xlsx нужен openpyxl (pip install openpyxl) — или сохрани таблицу в CSV.")
        ws = load_workbook(put, read_only=True, data_only=True).active
        rows = [[("" if v is None else str(v)).strip() for v in r] for r in ws.iter_rows(values_only=True)]
    else:
        with open(put, newline="", encoding="utf-8-sig") as f:
            rows = [[v.strip() for v in r] for r in csv.reader(f)]
    rows = [r for r in rows if any(r)]
    return rows[0], rows[1:]


def import_bazy(c, put, vladelec, karta=None, data=None):
    """Чужая база в наши поля. Все значения — «со слов передавшего», дата — из его таблицы или день получения.
    Совпал по нику с твоей базой — дописываем только пустые поля, человек остаётся твоим, источник добавляется."""
    zag, rows = prochitat_tablicu(put)
    karta_p = kolonki_v_polya(zag, karta)
    data = data or segodnya()
    novyh = obnovleno = 0
    for nomer, row in enumerate(rows, 2):
        z = dict(zip(zag, row + [""] * (len(zag) - len(row))))
        val = {}
        lishnee = []
        for kol, v in z.items():
            if not v:
                continue
            pole = karta_p.get(kol)
            if pole:
                val[pole] = (val[pole] + "; " + v) if pole in val else v
            else:
                lishnee.append(f"{kol}: {v}")
        if not val.get("name") and not val.get("username"):
            continue
        if lishnee:
            val["zametki"] = "; ".join(filter(None, [val.get("zametki"), *lishnee]))
        nik = (val.get("username") or "").lstrip("@").split("/")[-1] or None
        val["username"] = nik
        d = val.pop("data_svedeniy", None) or data
        r = c.execute("select id from people where lower(username)=lower(?)", (nik,)).fetchone() if nik else None
        if r:
            pid = r[0]
            pusto = [p for p in val if p != "username" and not c.execute(f"select {p} from people where id=?", (pid,)).fetchone()[0]]
            for p in pusto:
                c.execute(f"update people set {p}=? where id=?", (val[p], pid))
            otmetit(c, pid, [p for p in pusto if p != "name"], SOST["передавший"], d)
            obnovleno += 1
        else:
            pid = min(0, c.execute("select min(id) from people").fetchone()[0] or 0) - 1  # свои коды ниже нуля
            polya = [p for p in val if p in ("name", "username", "kompaniya", "rol", "zametki") + DELOVYE]
            c.execute(f"insert into people(id, vladelec, {', '.join(polya)}) values(?,?{', ?' * len(polya)})",
                      (pid, vladelec, *[val[p] for p in polya]))
            otmetit(c, pid, [p for p in polya if p not in ("name", "username")], SOST["передавший"], d)
            novyh += 1
        c.execute("insert or replace into istochniki values(?,?,?,?,?)",
                  (pid, "база партнёра", f"база {vladelec} — {Path(put).name}, строка {nomer}", "", datetime.now(timezone.utc).isoformat()))
    c.commit()
    return novyh, obnovleno, karta_p


DLYA_PARTNERA = [("kompaniya", "Компания"), ("rol", "Должность"), ("napravlenie", "Направление — что делает и для кого ◐"),
                 ("keysy", "Кейсы ◐"), ("masshtab", "Масштаб ◐"), ("resursy", "У него — ресурсы и выходы ◐"),
                 ("kto_nuzhen", "Запросы — что и кто ему нужен ◐"), ("svyaz", "Связь с нами"), ("data_svedeniy", "Дата обновления")]


def dlya_partnera(c, vladelec, put):
    """Копия партнёру на разметку: его люди в нашем формате, без наших внутренних полей (стадия 2, теплота, заметки)
    и 2 колонки — «Прислушается к тебе» (1–10) и «Доступ через тебя»."""
    c.row_factory = sqlite3.Row
    rows = [dict(r) for r in c.execute(
        "select distinct p.* from people p left join istochniki i on i.chat_id=p.id "
        "where p.vladelec=? or (i.tip='база партнёра' and i.ssylka like ?) order by p.id desc", (vladelec, f"база {vladelec} —%"))]
    c.row_factory = None
    put = Path(put)
    put.parent.mkdir(parents=True, exist_ok=True)
    with open(put, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["Код", "Имя и профиль", "Telegram"] + [z for _, z in DLYA_PARTNERA]
                   + ["Владелец контакта", "Прислушается к тебе — от 1 до 10", "Доступ через тебя: " + " / ".join(DOSTUP)])
        for r in rows:
            w.writerow([r["id"], " ".join(filter(None, [r["name"], r["profil"]])), r["username"] or ""]
                       + [r.get(p) or "" for p, _ in DLYA_PARTNERA] + [r.get("vladelec") or "есть и у нас", "", ""])
    return put, len(rows)


def prinyat_razmetku(c, put, vladelec):
    """Разметка партнёра обратно: «Прислушается к тебе» и «Доступ через тебя» — со слов передавшего, с датой.
    «Не берусь — не трогать» → его человек выпадает из выборок (ne_trogat). Если человек есть и в твоей базе,
    запрет касается только маршрута через партнёра — твоя связь с ним остаётся."""
    zag, rows = prochitat_tablicu(put)
    i_kod = zag.index("Код")
    i_pr = next(i for i, z in enumerate(zag) if z.startswith("Прислушается"))
    i_do = next(i for i, z in enumerate(zag) if z.startswith("Доступ через тебя"))
    prinyato = ne_trogat = 0
    for row in rows:
        row = row + [""] * (len(zag) - len(row))
        if not row[i_kod].lstrip("-").isdigit() or not (row[i_pr] or row[i_do]):
            continue
        pid = int(row[i_kod])
        pr = int(row[i_pr]) if row[i_pr].isdigit() and 1 <= int(row[i_pr]) <= 10 else None
        do = row[i_do] if row[i_do] in DOSTUP else None
        if row[i_do] and do is None:
            raise SystemExit(f"Код {pid}: «{row[i_do]}» — нет такого доступа. Есть: {', '.join(DOSTUP)}")
        c.execute("insert or replace into razmetka values(?,?,?,?,?)", (pid, vladelec, pr, do, segodnya()))
        if do == DOSTUP[-1]:
            ne_trogat += c.execute("update people set ne_trogat=1 where id=? and vladelec=?", (pid, vladelec)).rowcount
        prinyato += 1
    c.commit()
    return prinyato, ne_trogat


def cli(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("sobrat", help="Стадия 1: собрать или докачать индекс из лички Telegram")
    s.add_argument("--dney", type=int, default=365)
    s.add_argument("--min", type=int, default=5, help="Карточка — от N сообщений в переписке")
    s.add_argument("--limit", type=int, default=500, help="Сколько последних чатов просмотреть")
    iv = sub.add_parser("iz_vygruzki", help="Стадия 1 без Telegram: личка из сохранённой выгрузки (<id>.jsonl)")
    iv.add_argument("--papka", required=True)
    iv.add_argument("--imena", help="JSON {id: {imya, nik}} — имена и ники к диалогам")
    iv.add_argument("--min", type=int, default=5)
    rs = sub.add_parser("rasshifrovki", help="Стадия 1: с кем были созвоны — по расшифровкам в папке")
    rs.add_argument("--papka", required=True)
    rs.add_argument("--ya", default="", help="твои имена и ники через запятую — себя не считаем")
    rs.add_argument("--novye", action="store_true", help="заводить карточку и по имени без ника")
    sub.add_parser("stat", help="Сколько людей, теплота, деловые карточки, продукты, чужие базы")
    o = sub.add_parser("obrazec", help="Последние сообщения человека — ИИ читает и заполняет карточку")
    o.add_argument("--kto", required=True, help="код или ник без @")
    o.add_argument("--n", type=int, default=30)
    z = sub.add_parser("zapolnit", help="Стадия 1: дописать в карточку деловые поля, с состоянием и датой")
    z.add_argument("--kto", help="код или ник; без него — --fayl")
    z.add_argument("--fayl", help="карточки пачкой, JSON: [{id, data, otkuda, поля…, gipoteza: [...], isklyuchit}]")
    for pole in ("kompaniya", "rol", "chem", "zametki", "stil") + DELOVYE + MEHANIKA:
        z.add_argument(f"--{pole}")
    z.add_argument("--sost", choices=list(SOST), default="гипотеза", help="факт — его слова; передавший; гипотеза — вывод ИИ")
    z.add_argument("--data", help="дата сведений, ГГГГ-ММ-ДД; по умолчанию сегодня")
    oq = sub.add_parser("ochered", help="Плотное заполнение: кто с созвонами ещё не заполнен")
    oq.add_argument("--n", type=int, default=20)
    pa = sub.add_parser("pachka", help="Материал на следующих n из очереди: карточка, его речь, его сообщения")
    pa.add_argument("--n", type=int, default=30)
    pa.add_argument("--rech", type=int, default=1300, help="сколько знаков его речи из расшифровок на человека")
    pa.add_argument("--out", required=True)
    ik = sub.add_parser("isklyuchit", help="Не соцактив: личное, своя команда, второй аккаунт")
    ik.add_argument("--kto", required=True)
    ik.add_argument("--pochemu", default="", help="одной строкой; пусто — вернуть")
    so = sub.add_parser("socaktiv", help="Текущий соцактив: поля стадии 1 без полей с замком, без имён")
    so.add_argument("--out", required=True)
    so.add_argument("--dney", type=int, help="только созвон не старше N дней")
    so.add_argument("--vse", action="store_true", help="все с деловыми полями, не только с созвонами")
    ut = sub.add_parser("utechki", help="Проверить исходящую таблицу: ники, ссылки, контакты, фамилии")
    ut.add_argument("--fayl", required=True)
    i = sub.add_parser("istochnik", help="Технические поля: ссылка на то, что уже лежит у тебя по человеку")
    i.add_argument("--kto", required=True)
    i.add_argument("--tip", required=True, help="база, источник профиля, сохранённая переписка, расшифровка, CRM…")
    i.add_argument("--ssylka", required=True, help="путь к файлу или адрес")
    i.add_argument("--opisanie", default="")
    k = sub.add_parser("kartochka", help="Карточка человека целиком: поля с состояниями, источники, продукты, разметка")
    k.add_argument("--kto", required=True)
    ch = sub.add_parser("chat", help="Расширение базы: холодные кандидаты из закрытого чата, где ты состоишь")
    ch.add_argument("--chat", required=True, help="точное название, @ник или id чата")
    ch.add_argument("--soobshcheniy", type=int, default=3000, help="сколько последних сообщений чата смотреть")
    ch.add_argument("--vse", action="store_true", help="добавить и тех, кто в чате молчит (если список участников открыт)")
    h = sub.add_parser("holodnye", help="Холодные без решения — выбери, к кому интересно сходить самому")
    h.add_argument("--n", type=int, default=30)
    t = sub.add_parser("interes", help="Отметить холодного: интересно самому (или --net)")
    t.add_argument("--kto", required=True)
    t.add_argument("--net", action="store_true")
    n = sub.add_parser("pustye", help="Карточки без компании — их ИИ заполняет первыми")
    n.add_argument("--n", type=int, default=20)
    q = sub.add_parser("poisk", help="Найти людей под запрос своими словами")
    q.add_argument("zapros")
    q.add_argument("--top", type=int, default=15)
    pr = sub.add_parser("produkt", help="Стадии 2–3: завести продукт — свой или участника группы — с его интро")
    pr.add_argument("--kod", required=True, help="короткий код продукта латиницей или по-русски")
    pr.add_argument("--nazvanie", required=True)
    pr.add_argument("--chey", default="мой", help="«мой» или имя участника группы")
    pr.add_argument("--lider", default="", help="кто у тебя лидит этот продукт")
    pr.add_argument("--intro", required=True, help="файл интро: 5 пунктов разговора, слайд или упаковка")
    sub.add_parser("produkty", help="Список продуктов")
    pp = sub.add_parser("pod_produkt", help="Стадии 2–3: кандидаты под продукт по его интро — дальше ocenit")
    pp.add_argument("--produkt", required=True)
    pp.add_argument("--top", type=int, default=50)
    oc = sub.add_parser("ocenit", help="Стадии 2–3: оценка человека под продукт")
    oc.add_argument("--kto", required=True)
    oc.add_argument("--produkt", required=True)
    oc.add_argument("--kandidat", choices=("да", "нет"))
    oc.add_argument("--pochemu", help="почему: 3 за и 3 против брать в работу")
    oc.add_argument("--segment", choices=SEGMENTY)
    oc.add_argument("--status", help="статус воронки, почему ещё не купил и следующий шаг")
    oc.add_argument("--partner", choices=PARTNERY)
    oc.add_argument("--kakie", help="какие именно клиенты, маяки или джокеры у него")
    oc.add_argument("--balans", help="баланс ценности: что отгрузил ему и что он тебе — только факты")
    oc.add_argument("--kommenty", help="комменты и договорённости, в том числе кому передал контакт и статус")
    oc.add_argument("--zachem", help="зачем знакомим — одна строка для внешней таблицы")
    oc.add_argument("--sost", choices=list(SOST), default="гипотеза")
    ce = sub.add_parser("celevye", help="Итог стадии 2–3: кандидаты «да» по продукту, по сегментам")
    ce.add_argument("--produkt", required=True)
    ce.add_argument("--partner", choices=PARTNERY)
    ce.add_argument("--out", help="внутренняя таблица в CSV")
    vn = sub.add_parser("vneshnyaya", help="Стадия 3: внешняя таблица участнику — без имён и контактов")
    vn.add_argument("--produkt", required=True)
    vn.add_argument("--out", required=True)
    vn.add_argument("--polya", help="поля через запятую; по умолчанию компания, должность и 5 пунктов интро")
    v = sub.add_parser("sovpadeniya", help="Быстро: совпадения с любым текстом участника — внутренняя и внешняя таблица")
    v.add_argument("--fayl", required=True, help="интро участника, .md или .txt")
    v.add_argument("--top", type=int, default=30)
    v.add_argument("--out", required=True, help="Внутренняя таблица только для тебя; рядом появится внешняя — без имён")
    v.add_argument("--polya", help="поля внешней таблицы через запятую")
    ib = sub.add_parser("import_bazy", help="Чужая база: его таблица (CSV или XLSX) → наши поля, «со слов передавшего»")
    ib.add_argument("--fayl", required=True)
    ib.add_argument("--vladelec", required=True, help="кто передал базу — владелец её контактов")
    ib.add_argument("--karta", help="явно: «Колонка=pole;Колонка2=pole2» — если угадывание ошиблось")
    ib.add_argument("--data", help="дата сведений, если в его таблице её нет; по умолчанию сегодня")
    dp = sub.add_parser("dlya_partnera", help="Чужая база: копия партнёру на разметку доступа")
    dp.add_argument("--vladelec", required=True)
    dp.add_argument("--out", required=True)
    rz = sub.add_parser("razmetka", help="Чужая база: принять разметку партнёра обратно")
    rz.add_argument("--fayl", required=True)
    rz.add_argument("--vladelec", required=True)
    return p.parse_args(argv)


def pokazat_utechki(c, put):
    """Перечитать исходящую таблицу и назвать всё, по чему человека узнают. → число находок."""
    with open(put, newline="", encoding="utf-8") as f:
        stroki_ = list(csv.reader(f))[1:]
    nahodki = utechki(c, stroki_)
    if nahodki:
        print(f"⚠️ Проверь до отправки — находок {len(nahodki)}: "
              + "; ".join(f"строка {i}, {chto}: {m}" for i, chto, m in nahodki[:20]))
    return len(nahodki)


def najti(c, kto):
    kto = kto.lstrip("@")
    r = c.execute("select id, name from people where id=? or lower(username)=lower(?)",
                  (int(kto) if kto.lstrip("-").isdigit() else 0, kto)).fetchone()
    if not r:
        raise SystemExit("Такого человека в индексе нет. Сначала sobrat или import_bazy.")
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
    if a.command in ("sobrat", "chat"):
        lock = TG / ".telegram.lock"
        if lock.exists():
            raise SystemExit("Сессия Telegram занята другим процессом. Дождитесь его и повторите.")
        lock.write_text(str(os.getpid()))
        cl = klient()
        try:
            await cl.connect()
            if not await cl.is_user_authorized():
                raise SystemExit("Telegram не подключён. Сначала login в скиле podklyuchit-telegram.")
            if a.command == "sobrat":
                lyudey, novyh = await sobrat(cl, c, a.dney, a.min, a.limit)
            else:
                novyh, vsego = await iz_chata(cl, c, a.chat, a.soobshcheniy, a.vse)
        finally:
            await cl.disconnect()
            lock.unlink(missing_ok=True)
        if a.command == "sobrat":
            print(f"Карточек: {lyudey}, новых сообщений докачано: {novyh} → {DB}")
        else:
            print(f"Из чата: {vsego} человек, новых холодных {novyh}. Дальше holodnye — отметь, к кому интересно самому.")
    elif a.command == "iz_vygruzki":
        imena = json.loads(Path(a.imena).read_text(encoding="utf-8")) if a.imena else None
        lyudey, novyh = iz_vygruzki(c, a.papka, a.min, imena)
        print(f"Из выгрузки: карточек {lyudey}, новых сообщений {novyh} → {DB}")
    elif a.command == "rasshifrovki":
        faylov, svyazey, novyh, top = rasshifrovki(c, a.papka, [x.strip() for x in a.ya.split(",") if x.strip()], a.novye)
        print(f"Расшифровок с говорящими: {faylov} · новых связей «созвон» {svyazey} · новых карточек из созвонов {novyh}")
        if top:
            print("Не опознаны (нет ника и нет единственного совпадения по имени): "
                  + "; ".join(f"{m} ×{n}" for m, n in top[:15]))
    elif a.command == "stat":
        vsego = c.execute("select count(*) from people where stil is not null").fetchone()[0]
        t = dict(c.execute("select teplota, count(*) from people where stil is not null group by teplota").fetchall())
        pust = c.execute("select count(*) from people where stil is not null and kompaniya is null").fetchone()[0]
        delo = c.execute("select count(*) from people where napravlenie is not null").fetchone()[0]
        ist = c.execute("select count(distinct chat_id) from istochniki").fetchone()[0]
        sozv = c.execute("select count(*) from people where coalesce(sozvony, 0) > 0").fetchone()[0]
        print(f"Людей из лички: {vsego} · горячих {t.get('горячий', 0)} · тёплых {t.get('тёплый', 0)} · "
              f"оживить {t.get('оживить', 0)} · без компании {pust} · деловых карточек {delo} · с источниками {ist} · "
              f"созванивались по расшифровкам {sozv}")
        sost = dict(c.execute("select sost, count(*) from sostoyaniya group by sost").fetchall())
        if sost:
            print("Значений: " + " · ".join(f"{ZNAK[s]} {s} {sost.get(s, 0)}" for s in ZNAK))
        for kod, nazv, chey in c.execute("select kod, nazvanie, chey from produkty"):
            da = c.execute("select count(*) from pod_produkt where produkt=? and kandidat='да'", (kod,)).fetchone()[0]
            print(f"Продукт {kod} ({nazv}, {chey}): кандидатов «да» {da}")
        for vl, n in c.execute("select vladelec, count(*) from people where vladelec is not null group by vladelec"):
            rz = c.execute("select count(*) from razmetka where vladelec=?", (vl,)).fetchone()[0]
            print(f"Чужая база {vl}: людей {n} · размечено им {rz}")
        s_sozv = c.execute("select count(*) from people where (coalesce(sozvony,0)>0 or zvonki>0) and isklyuchen is null").fetchone()[0]
        isk = c.execute("select count(*) from people where isklyuchen is not null").fetchone()[0]
        print(f"С созвонами: {s_sozv} · плотно заполнено {s_sozv - len(ochered(c))} · в очереди {len(ochered(c))} · "
              f"исключено из соцактива {isk}")
        hol = c.execute("select count(*), sum(interes=1) from people where teplota='холодный'").fetchone()
        if hol[0]:
            print(f"Холодных из чатов: {hol[0]} · интересно самому {hol[1] or 0}")
    elif a.command == "obrazec":
        pid, name = najti(c, a.kto)
        print(f"# {name}")
        rows = c.execute("select date, out, golos, tekst from msgs where chat_id=? order by date desc limit ?", (pid, a.n))
        for d, out, golos, tekst in rows.fetchall()[::-1]:
            print(f"[{d[:10]}] {'я' if out else 'он'}: {'(голосовое) ' if golos else ''}{tekst}")
        for chat, n, obr in c.execute("select chat, soobshcheniy, obrazec from chat_msgs where user_id=?", (pid,)):
            print(f"[{chat}, сообщений {n}] {obr}")
    elif a.command == "zapolnit" and a.fayl:
        gotovo, isk, net = zapolnit_pachkoy(c, json.loads(Path(a.fayl).read_text(encoding="utf-8")))
        print(f"Карточек заполнено: {gotovo} · исключено из соцактива {isk}" + (f" · нет в индексе: {', '.join(net)}" if net else ""))
        print(f"В очереди осталось: {len(ochered(c))}")
    elif a.command == "zapolnit":
        if not a.kto:
            raise SystemExit("Нужен --kto или --fayl с карточками.")
        pid, name = najti(c, a.kto)
        polya = {"kompaniya": a.kompaniya, "rol": a.rol, "chem_polezen": a.chem, "zametki": a.zametki, "stil": a.stil,
                 **{p: getattr(a, p) for p in DELOVYE + MEHANIKA}}
        zapolneno = [k for k, v in polya.items() if v]
        for k in zapolneno:
            c.execute(f"update people set {k}=? where id=?", (polya[k], pid))
        otmetit(c, pid, zapolneno, SOST[a.sost], a.data or segodnya())
        c.commit()
        print(f"Карточка обновлена: {name} · полей {len(zapolneno)} · {ZNAK[SOST[a.sost]]} {SOST[a.sost]}")
    elif a.command == "ochered":
        q = ochered(c)
        print(f"В очереди {len(q)}: с расшифровками {sum(1 for r in q if r[0] == 0)}, только звонки в Telegram "
              f"{sum(1 for r in q if r[0] == 1)}")
        for _, posl, pid, name, un, puti in q[:a.n]:
            print(pid, name, f"@{un}" if un else "—", f"последний созвон {posl or '—'}", f"расшифровок {len(puti)}", sep=" · ")
    elif a.command == "pachka":
        tekst, n, ostalos = pachka(c, a.n, a.rech)
        put = Path(a.out).resolve()
        put.parent.mkdir(parents=True, exist_ok=True)
        put.write_text(tekst, encoding="utf-8")
        print(f"Пачка: {n} человек, {len(tekst)} знаков → {put} · осталось после неё {ostalos}")
    elif a.command == "isklyuchit":
        pid, name = najti(c, a.kto)
        isklyuchit(c, pid, a.pochemu)
        c.commit()
        print(f"{name}: " + (f"не соцактив — {a.pochemu}" if a.pochemu else "вернул в соцактив"))
    elif a.command == "socaktiv":
        rows, pusto, po_slovam, vsego = socaktiv(c, a.dney, a.vse)
        put = Path(a.out).resolve()
        put.parent.mkdir(parents=True, exist_ok=True)
        with open(put, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(SOCAKTIV)
            for nomer, r in enumerate(rows, 1):
                w.writerow([nomer] + r)
        print(f"Соцактив: {len(rows)} человек из {vsego} · направление ● его словами у {po_slovam} · "
              f"без деловых полей {pusto} — не вошли → {put}")
        pokazat_utechki(c, put)
    elif a.command == "utechki":
        if not pokazat_utechki(c, Path(a.fayl)):
            print("Утечек нет: ни ников, ни ссылок, ни контактов, ни фамилий из индекса.")
    elif a.command == "istochnik":
        pid, name = najti(c, a.kto)
        c.execute("insert or replace into istochniki values(?,?,?,?,?)",
                  (pid, a.tip, a.ssylka, a.opisanie, datetime.now(timezone.utc).isoformat()))
        c.commit()
        print(f"Источник подвязан: {name} · {a.tip}")
    elif a.command == "kartochka":
        pid, name = najti(c, a.kto)
        c.row_factory = sqlite3.Row
        r = c.execute("select * from people where id=?", (pid,)).fetchone()
        sost = {s["pole"]: s for s in c.execute("select pole, sost, data from sostoyaniya where chat_id=?", (pid,))}
        print(f"код {pid} · {r['name']}" + (f" · @{r['username']}" if r["username"] else "")
              + f" · владелец: {r['vladelec'] or 'мой'}" + (" · НЕ ТРОГАТЬ" if r["ne_trogat"] else ""))
        if r["zvonki"] or r["sozvony"]:
            print(f"Созвоны: в Telegram {r['zvonki'] or 0} · по расшифровкам {r['sozvony'] or 0}")
        for kk in ("teplota", "stil", "yazyk", "format", "ton", "profil", "kompaniya", "rol", "napravlenie", "keysy",
                   "masshtab", "resursy", "kto_nuzhen", "svyaz", "chem_polezen", "zametki", "data_svedeniy"):
            if r[kk]:
                s = sost.get(kk)
                print(f"{METKI.get(kk, kk)}: {r[kk]}" + (f"  {ZNAK[s['sost']]} {s['sost']}, {s['data']}" if s else ""))
        for s in c.execute("select tip, ssylka, opisanie from istochniki where chat_id=?", (pid,)):
            print(f"источник · {s['tip']}: {s['ssylka']}" + (f" — {s['opisanie']}" if s["opisanie"] else ""))
        for o in c.execute("select * from pod_produkt where chat_id=?", (pid,)):
            print(f"продукт {o['produkt']}: {o['kandidat'] or '?'} · сегмент {o['segment'] or '—'} · {o['partner'] or ''} "
                  f"· {o['status'] or ''} · {ZNAK.get(o['sost'], '')} {o['data'] or ''}")
        for z in c.execute("select * from razmetka where chat_id=?", (pid,)):
            print(f"разметка {z['vladelec']}: прислушается {z['prislushaetsya'] or '—'}/10 · {z['dostup'] or '—'} · {z['data']}")
        c.row_factory = None
    elif a.command == "holodnye":
        for pid, name, un, chat, n, obr in c.execute(
                "select p.id, p.name, p.username, m.chat, m.soobshcheniy, m.obrazec from people p join chat_msgs m "
                "on m.user_id=p.id where p.teplota='холодный' and p.interes is null order by m.soobshcheniy desc limit ?", (a.n,)):
            print(pid, name, f"@{un}" if un else "—", chat, f"сообщений {n}", (obr or "")[:200], sep=" · ")
    elif a.command == "interes":
        pid, name = najti(c, a.kto)
        c.execute("update people set interes=? where id=?", (0 if a.net else 1, pid))
        c.commit()
        print(f"{name}: {'не берём' if a.net else 'интересно самому — идёт в совпадения'}")
    elif a.command == "pustye":
        for pid, name, msgs, tep in c.execute("select id, name, msgs, teplota from people where stil is not null "
                                              "and kompaniya is null and isklyuchen is null order by msgs desc limit ?", (a.n,)):
            print(pid, name, f"сообщений {msgs}", tep, sep=" · ")
    elif a.command == "poisk":
        for _, r, hit in sovpadeniya(c, a.zapros, a.top):
            print(r["id"], r["name"], r["kompaniya"] or "—", r["rol"] or "—", r["teplota"], "совпало: " + ", ".join(hit), sep=" · ")
    elif a.command == "produkt":
        intro = Path(a.intro).resolve()
        if not intro.exists():
            raise SystemExit(f"Нет файла интро: {intro}")
        c.execute("insert or replace into produkty values(?,?,?,?,?)", (a.kod, a.nazvanie, a.chey, a.lider, str(intro)))
        c.commit()
        print(f"Продукт {a.kod}: {a.nazvanie} · {a.chey}" + (f" · лидит {a.lider}" if a.lider else ""))
    elif a.command == "produkty":
        for kod, nazv, chey, lider, intro in c.execute("select * from produkty"):
            print(kod, nazv, chey, lider or "—", intro, sep=" · ")
    elif a.command == "pod_produkt":
        kod, nazv, chey, lider, intro = produkt_ili_stop(c, a.produkt)
        ocenki = dict(c.execute("select chat_id, kandidat from pod_produkt where produkt=?", (kod,)).fetchall())
        for _, r, hit in sovpadeniya(c, Path(intro).read_text(encoding="utf-8"), a.top):
            print(r["id"], r["name"], r["kompaniya"] or "—", r["rol"] or "—", r["teplota"] or "—",
                  "оценка: " + (ocenki.get(r["id"]) or "нет"), "совпало: " + ", ".join(hit), sep=" · ")
        print(f"Дальше по каждому: obrazec и ocenit --produkt {kod} --kandidat да|нет --pochemu … --segment A|B|C …")
    elif a.command == "ocenit":
        pid, name = najti(c, a.kto)
        produkt_ili_stop(c, a.produkt)
        polya = {k: getattr(a, k) for k in ("kandidat", "pochemu", "segment", "status", "partner", "kakie", "balans",
                                           "kommenty", "zachem")}
        c.execute("insert or ignore into pod_produkt(chat_id, produkt) values(?,?)", (pid, a.produkt))
        for k, v in polya.items():
            if v:
                c.execute(f"update pod_produkt set {k}=? where chat_id=? and produkt=?", (v, pid, a.produkt))
        c.execute("update pod_produkt set sost=?, data=? where chat_id=? and produkt=?", (SOST[a.sost], segodnya(), pid, a.produkt))
        c.commit()
        print(f"Оценка: {name} → {a.produkt} · {a.kandidat or 'без решения'} · {ZNAK[SOST[a.sost]]} {SOST[a.sost]}")
    elif a.command == "celevye":
        produkt_ili_stop(c, a.produkt)
        rows = celevye(c, a.produkt, a.partner)
        for r in rows:
            print(r["segment"] or "—", r["id"], r["name"], r["kompaniya"] or "—", r["partner"] or "клиент",
                  r["status"] or "—", sep=" · ")
        if a.out:
            put = Path(a.out).resolve()
            put.parent.mkdir(parents=True, exist_ok=True)
            with open(put, "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(["Код", "Имя", "Компания", "Должность", "Сегмент", "Партнёр", "Какие", "Почему: 3 за и 3 против",
                            "Статус воронки и следующий шаг", "Баланс ценности", "Комменты и договорённости", "Теплота",
                            "Состояние", "Дата"])
                for r in rows:
                    w.writerow([r["id"], r["name"], r["kompaniya"] or "", r["rol"] or "", r["segment"] or "", r["partner"] or "",
                                r["kakie"] or "", r["pochemu"] or "", r["status"] or "", r["balans"] or "", r["kommenty"] or "",
                                r["teplota"] or "", r["osost"] or "", r["odata"] or ""])
            print("Целевые (внутренняя таблица):", put)
    elif a.command == "vneshnyaya":
        produkt_ili_stop(c, a.produkt)
        polya = vneshnie_polya(a.polya)
        rows = celevye(c, a.produkt)
        put = Path(a.out).resolve()
        put.parent.mkdir(parents=True, exist_ok=True)
        with open(put, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["№"] + [METKI[p] for p in polya] + ["Зачем знакомим"])
            for nomer, r in enumerate(rows, 1):
                w.writerow([nomer] + [bez_imen(r.get(p)) for p in polya] + [bez_imen(r["zachem"])])
        print(f"Внешняя таблица для участника: {len(rows)} человек, без имён и контактов → {put}")
        pokazat_utechki(c, put)
    elif a.command == "sovpadeniya":
        polya = vneshnie_polya(a.polya)
        rows = sovpadeniya(c, Path(a.fayl).read_text(encoding="utf-8"), a.top)
        ist = {}
        for pid, tip, ssylka in c.execute("select chat_id, tip, ssylka from istochniki"):
            ist[pid] = (ist.get(pid, "") + "; " if pid in ist else "") + f"{tip}: {ssylka}"
        out = Path(a.out).resolve()
        zapisat(rows, out, True, istochniki=ist)
        bez = zapisat(rows, out.with_name(out.stem + "_bez_imen" + out.suffix), False, polya)
        print(f"Совпадений: {len(rows)} → {out} (внутренняя, только у тебя) · {bez} — внешняя, можно отдавать участнику")
        pokazat_utechki(c, bez)
    elif a.command == "import_bazy":
        novyh, obnovleno, karta = import_bazy(c, a.fayl, a.vladelec, a.karta, a.data)
        print("Колонки → поля: " + "; ".join(f"{k} → {v}" for k, v in karta.items()))
        print(f"База {a.vladelec}: новых {novyh}, совпали с твоей базой {obnovleno} · всё ◐ со слов передавшего")
    elif a.command == "dlya_partnera":
        put, n = dlya_partnera(c, a.vladelec, a.out)
        print(f"Копия для {a.vladelec}: {n} человек, 2 колонки на разметку → {put}")
    elif a.command == "razmetka":
        prinyato, ne_trogat = prinyat_razmetku(c, a.fayl, a.vladelec)
        print(f"Разметка {a.vladelec}: принято {prinyato} · «не трогать» {ne_trogat} — выпали из выборок")


if __name__ == "__main__":
    asyncio.run(run(cli()))
