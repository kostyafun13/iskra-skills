"""Сторож нагрузки на Telegram: свежий вход не сканирует всё сразу.

Зачем: новое устройство, которое сразу читает всю переписку, для Telegram похоже на взлом.
Сторож считает обращения к Telegram, ведёт ступени разгона по возрасту входа, тормозит длинные
запуски и останавливает работу при отказе Telegram. Состояние — private/nagruzka.json рядом со скриптом.

Ступени: первые сутки — только пробы; вторые и третьи — скан порциями; дальше — обычный режим.
Числа — запас осторожности, а не лимиты Telegram: свои пороги Telegram не публикует.
Сторожем пользуются telegram_app.py и скан базы из скила indeks-bazy. Счёт общий, потому что вход один.
Только стандартная библиотека: модуль грузится и без Telethon.
"""
import asyncio
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import random
import time
import uuid

# Часов после входа (верхняя граница) · обращений за скользящие сутки · пауза между обращениями, с · название.
# Одна команда — это 3–6 обращений: подключение само делает три.
STUPENI = (
    (24, 150, (2.0, 4.0), "пробы, первые сутки"),
    (48, 600, (1.5, 3.0), "разгон, вторые сутки"),
    (72, 1500, (1.0, 2.0), "разгон, третьи сутки"),
    (None, 3000, (0.3, 0.7), "обычный режим"),
)
SKAN_CHASOV = 24        # большой скан базы — не раньше чем через сутки после входа
UCHASTNIKI_CHASOV = 72  # список участников чата — только в обычном режиме
MIN_SKAN = 30           # скан с меньшим остатком не начинаем: он потратит остаток на подключение и встанет
BEZ_PAUZY_SVEZHIY = 5   # столько первых обращений запуска идут без паузы, пока вход свежий
BEZ_PAUZY_OBYCHNYY = 50  # и столько — в обычном режиме: короткие команды не замедляются
ZAPAS = 300             # длинный чат дочитываем: запуск может выйти за остаток не больше чем на столько
PAUZA_CHAT = (3, 6)     # секунд между чатами в большом скане
SBROS_KAZHDYE = 25      # раз во столько обращений счёт пишется в файл: отчёт виден и во время скана
SUTKI = timedelta(hours=24)
SLEPOY = ("Внимание: сторож нагрузки не увидел ни одного обращения к Telegram. Счёт не работает: "
          "обнови скил podklyuchit-telegram, большие чтения и скан пока не запускай.")
# Служебные обращения самой библиотеки: считаем, но не тормозим и на них не обрываем — иначе рвётся связь.
SLUZHEBNYE = {"GetStateRequest", "GetDifferenceRequest", "GetChannelDifferenceRequest"}

# Вид команды: что её останавливает.
#   sluzhba  — login, status: только названный Telegram срок ожидания
#   otpravka — отправка по поручению и её проверки: любой стоп, но не дневной запас; идёт без пауз
#   chtenie  — чтение чатов и вложений: любой стоп и дневной запас
#   skan     — большой скан базы: всё то же и первые сутки после входа
#   uchastniki — список участников чата: всё то же и первые трое суток
VIDY = ("sluzhba", "otpravka", "chtenie", "skan", "uchastniki")
S_PAUZAMI = ("chtenie", "skan", "uchastniki")
NEIZVESTNO = "неизвестно — считаю свежим"


class Pritormozi(Exception):
    """Запуск вышел за дневной запас обращений. Продолжение — позже."""


def seychas():
    return datetime.now(timezone.utc)


def iso(t):
    return t.astimezone(timezone.utc).isoformat(timespec="seconds")


def iz_iso(s):
    return datetime.fromisoformat(s)


def chasy(t):
    """Время для человека: по часам этого компьютера."""
    return t.astimezone().strftime("%d.%m %H:%M")


def put(root):
    return Path(root) / "private" / "nagruzka.json"


def prochitat(root):
    """Нет файла — пустое состояние. Файл занят — ждём и повторяем: иначе следующая запись сотрёт стоп и отметку входа."""
    f = put(root)
    for popytka in range(5):
        try:
            return json.loads(f.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}
        except ValueError:
            return {}  # файл испорчен: возраст входа возьмём заново, счёт начнём с нуля
        except OSError:
            if popytka == 4:
                raise
            time.sleep(0.2)


def sohranit(root, sost):
    f = put(root)
    f.parent.mkdir(parents=True, exist_ok=True)
    vremennyy = f.with_name(f.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        fd = os.open(vremennyy, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(json.dumps(sost, ensure_ascii=False, indent=2) + "\n")
        for popytka in range(5):
            try:
                os.replace(vremennyy, f)
                break
            except PermissionError:  # Windows: файл в этот миг читает отчёт или антивирус
                if popytka == 4:
                    raise
                time.sleep(0.2)
    finally:
        vremennyy.unlink(missing_ok=True)


def vremya_vhoda(root, sost, now):
    """Когда создан вход. Новый вход отмечает login. Для входа, сделанного до сторожа, берём дату создания
    файла входа. Дату узнать нельзя — считаем вход свежим: так безопаснее."""
    if sost.get("vhod"):
        return iz_iso(sost["vhod"])
    f = Path(root) / "personal_telegram.session"
    t = None
    if f.exists():
        st = f.stat()
        t = getattr(st, "st_birthtime", None)
        if t is None and os.name == "nt":
            t = st.st_ctime  # в Windows это время создания
    vhod = datetime.fromtimestamp(t, timezone.utc) if t else now
    sost["vhod"] = iso(min(vhod, now))
    sost["vhod_otkuda"] = "дата файла входа" if t else NEIZVESTNO
    return iz_iso(sost["vhod"])


def otmetit_vhod(root, now=None):
    """Новый вход выполнен: разгон начинается заново, расход прежнего входа в счёт не идёт."""
    now = now or seychas()
    sost = prochitat(root)
    sost["vhod"], sost["vhod_otkuda"], sost["vhod_rabotal"] = iso(now), "login", True
    sost["seansy"] = []
    sohranit(root, sost)


def podtverdit_davniy_vhod(root, now=None):
    """Владелец подтверждает: вход сделан больше трёх суток назад. Только когда дату входа не отметил login."""
    now = now or seychas()
    sost = prochitat(root)
    vhod = vremya_vhoda(root, sost, now)
    if sost.get("vhod_otkuda") == "login":
        return f"Вход сделан командой login {chasy(vhod)}: дата известна, менять её нельзя."
    sost["vhod"] = iso(now - timedelta(hours=UCHASTNIKI_CHASOV, minutes=1))
    sost["vhod_otkuda"] = "со слов владельца: вход давний"
    sohranit(root, sost)
    return "Записал со слов владельца: вход сделан больше трёх суток назад. Режим обычный."


def vhod_propal(root):
    """Входа нет. Если раньше он работал — это тревожный знак: текст для владельца. Иначе None."""
    if not prochitat(root).get("vhod_rabotal"):
        return None
    return ("Вход пропал: раньше он работал, теперь Telegram его не признаёт. Либо владелец сам завершил его в "
            "Устройствах, либо вход закрыл Telegram. Сразу новый вход не делай. Владелец смотрит сообщения от Telegram "
            "и Настройки → Устройства. Новый вход — только по его решению; после него разгон начнётся заново, с суток проб.")


def stupen(vhod, t):
    """Ступень на момент t: (предел за сутки, пауза, название, когда начнётся следующая)."""
    for chasov, predel, pauza, nazvanie in STUPENI:
        if chasov is None or t < vhod + timedelta(hours=chasov):
            return predel, pauza, nazvanie, (vhod + timedelta(hours=chasov)) if chasov else None
    raise AssertionError("последняя ступень без границы")


def zapuski(sost):
    """Все учтённые запуски: завершённые и текущий (или оборванный)."""
    rows = [tuple(x) for x in sost.get("seansy", [])]
    if sost.get("tekushchiy"):
        rows.append(tuple(sost["tekushchiy"]))
    return rows


def ispolzovano(sost, t):
    """Обращений за сутки перед моментом t."""
    return sum(n for kogda, n, _ in zapuski(sost) if t - SUTKI < iz_iso(kogda) <= t)


def ostatok_v(sost, vhod, t):
    """Сколько обращений остаётся в дневном запасе на момент t."""
    return max(stupen(vhod, t)[0] - ispolzovano(sost, t), 0)


def kogda_mozhno(sost, vhod, now, nuzhno=None):
    """Ближайший момент, когда в запасе будет не меньше nuzhno обращений (по умолчанию — больше, чем сейчас):
    старые запуски уходят из суток, ступень растёт."""
    if nuzhno is None:
        nuzhno = ostatok_v(sost, vhod, now) + 1
    momenty = [iz_iso(kogda) + SUTKI for kogda, _, _ in zapuski(sost)]
    momenty += [vhod + timedelta(hours=chasov) for chasov, *_ in STUPENI if chasov]
    for t in sorted(x for x in momenty if x > now):
        t += timedelta(seconds=1)
        if ostatok_v(sost, vhod, t) >= nuzhno:
            return t
    return now + SUTKI


def deystvuyushchiy_stop(sost, now):
    """Стоп, который действует сейчас, с пометкой zhdat — идёт ли названный Telegram срок. Иначе None.
    Стоп уровня аккаунта (razbor) сам не проходит: его снимает только владелец."""
    stop = sost.get("stop")
    if not stop:
        return None
    zhdat = bool(stop.get("ne_ranshe")) and now < iz_iso(stop["ne_ranshe"])
    razbor = stop.get("razbor", not stop.get("ne_ranshe"))
    if not zhdat and not razbor:
        return None
    return {**stop, "zhdat": zhdat, "razbor": bool(razbor)}


def svodka(root, now=None, sost=None):
    """Всё, что нужно для решения и для отчёта. Возраст входа при первом вызове запоминается."""
    now = now or seychas()
    svoy = sost is None
    sost = prochitat(root) if svoy else sost
    bylo = sost.get("vhod")
    vhod = vremya_vhoda(root, sost, now)
    if svoy and not bylo:
        sohranit(root, sost)
    predel, pauza, nazvanie, sleduyushchaya = stupen(vhod, now)
    ispolz = ispolzovano(sost, now)
    ostatok = max(predel - ispolz, 0)
    return {"now": now, "vhod": vhod, "vhod_otkuda": sost.get("vhod_otkuda"), "chasov": (now - vhod).total_seconds() / 3600,
            "predel": predel, "pauza": pauza, "stupen": nazvanie, "sleduyushchaya": sleduyushchaya,
            "ispolzovano": ispolz, "ostatok": ostatok, "stop": deystvuyushchiy_stop(sost, now),
            "svezhiy": sleduyushchaya is not None, "mozhno": kogda_mozhno(sost, vhod, now),
            "mozhno_skan": now if ostatok >= MIN_SKAN else kogda_mozhno(sost, vhod, now, MIN_SKAN),
            "skan_s": vhod + timedelta(hours=SKAN_CHASOV), "uchastniki_s": vhod + timedelta(hours=UCHASTNIKI_CHASOV)}


def tekst_stopa(stop):
    if stop.get("zhdat"):
        return (f"Telegram просил подождать ({stop['prichina']}). До {chasy(iz_iso(stop['ne_ranshe']))} к Telegram "
                "не обращаюсь: ни чтением, ни отправкой. Раньше не повторяй и другим способом не обходи.")
    return (f"Telegram отказал: {stop.get('prichina_razbora') or stop['prichina']}. Работа с Telegram остановлена "
            "до решения владельца. Владелец смотрит Telegram → Настройки → Устройства и сообщения от Telegram. "
            "Новый вход сразу не делай. Продолжить по слову владельца: команда nagruzka --snyat-stop.")


def pro_datu_vhoda(sv):
    """Подсказка, когда дату входа узнать не удалось и вход считается свежим."""
    if sv["vhod_otkuda"] != NEIZVESTNO:
        return ""
    return (" Дату входа узнать не удалось, поэтому считаю его свежим. Если вход сделан больше трёх суток назад, "
            "владелец подтверждает это командой nagruzka --vhod-davniy.")


def proverit(root, vid, now=None):
    """Перед выходом в сеть: можно ли этой команде работать сейчас. Нельзя — понятный отказ и срок."""
    if vid not in VIDY:
        raise ValueError(vid)
    sv = svodka(root, now)
    stop = sv["stop"]
    if stop and (stop["zhdat"] or vid != "sluzhba"):
        raise SystemExit(tekst_stopa(stop))
    if vid in ("skan", "uchastniki") and sv["now"] < sv["skan_s"]:
        raise SystemExit(
            f"Вход свежий: прошло {int(sv['chasov'])} ч. Большой скан в первые сутки не запускаю: новое устройство, "
            f"которое сразу читает всю переписку, для Telegram похоже на взлом. Сегодня — только пробы: пара чатов "
            f"и каналы. Скан откроется {chasy(sv['skan_s'])} и пойдёт порциями 2–3 суток." + pro_datu_vhoda(sv))
    if vid == "uchastniki" and sv["now"] < sv["uchastniki_s"]:
        raise SystemExit(f"Список участников чата — не раньше {chasy(sv['uchastniki_s'])}: первые трое суток после входа "
                         "его не собираю. Сам чат читать можно: та же команда без --vse." + pro_datu_vhoda(sv))
    if vid in ("skan", "uchastniki") and sv["ostatok"] < MIN_SKAN:
        raise SystemExit(
            f"Притормози: за сутки уже {sv['ispolzovano']} обращений к Telegram из {sv['predel']} "
            f"(ступень «{sv['stupen']}»). Скан продолжится после {chasy(sv['mozhno_skan'])}: докачает с места.")
    if vid == "chtenie" and sv["ostatok"] <= 0:
        raise SystemExit(
            f"Притормози: за сутки уже {sv['ispolzovano']} обращений к Telegram из {sv['predel']} "
            f"(ступень «{sv['stupen']}»). Читать дальше можно после {chasy(sv['mozhno'])}. "
            "Отправка по поручению владельца работает." + pro_datu_vhoda(sv))
    return sv


def nachat(root, klient, sv, vid, komanda):
    """Настроить клиента перед работой: паузы, остаток, учёт текущего запуска."""
    sost = prochitat(root)
    if sost.get("tekushchiy"):  # прошлый запуск оборвался: его обращения всё равно были
        sost.setdefault("seansy", []).append(sost.pop("tekushchiy"))
    sost["tekushchiy"] = [iso(sv["now"]), 0, komanda]
    sohranit(root, sost)
    klient.koren, klient.komanda, klient.nachat_v = root, komanda, sv["now"]
    if vid in S_PAUZAMI:  # вход и отправка идут без пауз: код живёт недолго, а отправку нельзя растягивать
        klient.pauza = sv["pauza"]
        klient.bez_pauzy = BEZ_PAUZY_SVEZHIY if sv["svezhiy"] else BEZ_PAUZY_OBYCHNYY
        klient.ostatok = sv["ostatok"]
        klient.predel = sv["ostatok"] + ZAPAS
    if vid in ("skan", "uchastniki"):
        klient.pauza_chat = PAUZA_CHAT


def zakonchit(root, klient, now=None, vhod_rabotal=False):
    """После работы: запуск уходит в журнал, записи старше суток убираются."""
    now = now or seychas()
    sost = prochitat(root)
    sost.pop("tekushchiy", None)
    if vhod_rabotal:
        sost["vhod_rabotal"] = True
    n = getattr(klient, "zaprosov", 0)
    if n:
        sost.setdefault("seansy", []).append([iso(getattr(klient, "nachat_v", None) or now), n, getattr(klient, "komanda", "")])
    sost["seansy"] = [x for x in sost.get("seansy", []) if iz_iso(x[0]) > now - SUTKI]
    sohranit(root, sost)


def vid_otkaza(oshibka):
    """zhdat — Telegram назвал срок всему аккаунту; razbor — отказ уровня аккаунта, решает владелец;
    None — обычная ошибка одного чата или одного действия."""
    rodnya = {c.__name__ for c in type(oshibka).__mro__}
    if rodnya & {"SlowModeWaitError", "FloodPremiumWaitError"}:
        return None  # медленный режим одного чата и очередь скачивания без Premium — не отказ аккаунту
    if getattr(oshibka, "seconds", None) and rodnya & {"FloodError", "FloodWaitError"}:
        return "zhdat"
    if rodnya & {"FloodError", "UnauthorizedError", "PeerFloodError"}:
        return "razbor"
    return None


def zapisat_otkaz(root, oshibka, komanda, now=None):
    """Отказ Telegram уровня аккаунта → стоп в файле и текст для владельца. Обычная ошибка чата → None.
    Стоп «до слова владельца» новым сроком не затирается: срок пройдёт, а решение владельца всё ещё нужно."""
    vid = vid_otkaza(oshibka)
    if vid is None:
        return None
    now = now or seychas()
    sost = prochitat(root)
    prezhniy = deystvuyushchiy_stop(sost, now) or {}
    imya = type(oshibka).__name__
    srok = now + timedelta(seconds=int(oshibka.seconds) + 60) if vid == "zhdat" else None
    if prezhniy.get("zhdat") and (srok is None or iz_iso(prezhniy["ne_ranshe"]) > srok):
        srok = iz_iso(prezhniy["ne_ranshe"])  # прежний срок длиннее — остаётся он
    stop = {"prichina": imya, "kogda": iso(now), "komanda": komanda, "ne_ranshe": iso(srok) if srok else None,
            "razbor": vid == "razbor" or bool(prezhniy.get("razbor"))}
    if stop["razbor"]:
        stop["prichina_razbora"] = imya if vid == "razbor" else prezhniy.get("prichina_razbora") or prezhniy.get("prichina")
    sost["stop"] = stop
    sost.setdefault("otkazy", []).append([iso(now), imya, komanda])
    sost["otkazy"] = sost["otkazy"][-20:]
    sohranit(root, sost)
    return "Стоп. " + tekst_stopa(deystvuyushchiy_stop(sost, now))


def snyat_stop(root, now=None):
    """Снять стоп по слову владельца. Названный Telegram срок раньше времени не снимается."""
    now = now or seychas()
    sost = prochitat(root)
    stop = deystvuyushchiy_stop(sost, now)
    if not stop:
        return "Стопа нет."
    if stop["zhdat"]:
        return f"Telegram назвал срок: раньше {chasy(iz_iso(stop['ne_ranshe']))} стоп не снимаю."
    sost["stop"] = None
    sohranit(root, sost)
    return "Стоп снят. Начни с малого: одна проба, потом работа."


def stroka(root, now=None):
    """Одна строка после команды. Пустая, когда вход давний и нагрузка низкая."""
    sv = svodka(root, now)
    dolya = sv["ispolzovano"] / sv["predel"]
    if not sv["svezhiy"] and dolya < 0.5:
        return ""
    s = f"Нагрузка: {sv['ispolzovano']} из {sv['predel']} обращений за сутки · ступень «{sv['stupen']}»."
    if dolya >= 0.8:
        s += f" Притормози: в запасе осталось {sv['ostatok']}. Больше станет после {chasy(sv['mozhno'])}."
    elif sv["now"] < sv["skan_s"]:
        s += f" Вход свежий: сегодня только пробы, большой скан — с {chasy(sv['skan_s'])}."
    return s


def otchet(root, now=None):
    """Отчёт для владельца: ступень, расход, что открыто и что советуем. Сеть не нужна."""
    sv = svodka(root, now)
    ch = int(sv["chasov"])
    davno = f"{ch} ч назад" if ch < 72 else f"{ch // 24} сут назад"
    rows = [f"Вход: {chasy(sv['vhod'])} ({davno}; источник: {sv['vhod_otkuda']}). Ступень: {sv['stupen']}.",
            f"Обращений к Telegram за сутки: {sv['ispolzovano']} из {sv['predel']}. Осталось: {sv['ostatok']}."]
    if sv["stop"]:
        rows.append(tekst_stopa(sv["stop"]))
    if sv["now"] < sv["skan_s"]:
        rows.append(f"Большой скан базы: закрыт до {chasy(sv['skan_s'])}.")
    elif sv["ostatok"] < MIN_SKAN:
        rows.append(("Чтение и скан" if sv["ostatok"] <= 0 else "Большой скан базы") + f": пауза до {chasy(sv['mozhno_skan'])}.")
    else:
        rows.append("Большой скан базы: открыт, идёт порциями в пределах дневного запаса.")
    if sv["svezhiy"]:
        p = [predel for _, predel, _, _ in STUPENI]
        rows.append(f"Разгон: первые сутки — до {p[0]} обращений, вторые — до {p[1]}, третьи — до {p[2]}, дальше — до {p[3]} в сутки. "
                    "Одна команда — это 3–6 обращений.")
        rows.append("Совет: сегодня только пробы — пара чатов и каналы. Скан базы начни через сутки после входа."
                    if sv["now"] < sv["skan_s"] else
                    "Совет: скан базы запускай раз в сутки той же командой. Он докачивает с места и сам остановится на пределе.")
        if pro_datu_vhoda(sv):
            rows.append(pro_datu_vhoda(sv).strip())
    elif sv["ispolzovano"] >= 0.8 * sv["predel"]:
        rows.append("Совет: притормози. Запас на сутки почти выбран; большие чтения перенеси на завтра.")
    rows.append("Числа — запас осторожности, а не лимиты Telegram. Любой отказ Telegram останавливает работу до срока.")
    return "\n".join(rows)


class Schetchik:
    """Примесь к TelegramClient: считает обращения, тормозит длинный запуск, не даёт уйти далеко за остаток.
    Части файлов при скачивании вложений считаются отдельно и в дневной запас не входят."""
    zaprosov = 0
    chastey_faylov = 0
    pauza = None        # (от, до) секунд между обращениями
    bez_pauzy = 0       # столько первых обращений без паузы
    ostatok = None      # дневной запас на начало запуска
    predel = None       # жёсткий потолок запуска: остаток плюс запас на длинный чат
    pauza_chat = None   # (от, до) секунд между чатами — для большого скана
    koren = None
    komanda = ""
    nachat_v = None

    async def _call(self, sender, request, ordered=False, flood_sleep_threshold=None):
        imya = type(request).__name__
        if imya == "GetFileRequest":
            self.chastey_faylov += 1
        elif imya in SLUZHEBNYE:
            self.zaprosov += 1
        else:
            if self.predel is not None and self.zaprosov >= self.predel:
                raise Pritormozi(f"Притормози: запуск сделал {self.zaprosov} обращений к Telegram и вышел за дневной запас. "
                                 "Продолжение — после срока из команды nagruzka.")
            self.zaprosov += 1
            if self.koren is not None and self.zaprosov % SBROS_KAZHDYE == 0:
                self.sbros()
            if self.pauza and self.zaprosov > self.bez_pauzy:
                await asyncio.sleep(random.uniform(*self.pauza))
        return await super()._call(sender, request, ordered=ordered, flood_sleep_threshold=flood_sleep_threshold)

    def sbros(self):
        """Записать промежуточный счёт: отчёт во время длинного скана показывает правду, обрыв не теряет расход."""
        try:
            sost = prochitat(self.koren)
            sost["tekushchiy"] = [iso(self.nachat_v or seychas()), self.zaprosov, self.komanda]
            sohranit(self.koren, sost)
        except OSError:
            pass  # файл занят: счёт запишется в следующий раз, скан из-за этого не рвём

    def hvatit(self):
        """Для скана: дневной запас выбран — остановиться на границе чата."""
        return self.ostatok is not None and self.zaprosov >= self.ostatok
