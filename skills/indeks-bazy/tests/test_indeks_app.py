"""Изолированная проверка индекса: без сети и без настоящей сессии."""
import csv
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "scripts" / "indeks_app.py"
spec = importlib.util.spec_from_file_location("indeks_app", path)
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
NOW = datetime.now(timezone.utc)
AT = "@"  # тестовые ники выдуманные; собраны из частей, чтобы аудит публикации не путал их с настоящими


def m(mid, text="Привет, как ты?", out=False, hours_ago=1, voice=False, action=None):
    return SimpleNamespace(id=mid, message=text, out=out, date=NOW - timedelta(hours=hours_ago),
                           voice=object() if voice else None, action=action)


class Dialog:
    def __init__(self, did, name, last, is_user=True, bot=False):
        self.id, self.name, self.message, self.is_user, self.pinned = did, name, last, is_user, False
        self.entity = SimpleNamespace(id=did, bot=bot, username=f"user{did}")


class Client:
    def __init__(self):
        self.history = {201: [m(i, out=i % 2 == 0, hours_ago=100 - i) for i in range(1, 9)]}
        self.dialogs = [Dialog(201, "Анна", self.history[201][-1]), Dialog(202, "Бот", m(1), bot=True),
                        Dialog(203, "Группа", m(1), is_user=False)]
        self.calls = []

    async def iter_dialogs(self, limit=None):
        for d in self.dialogs:
            yield d

    async def iter_messages(self, entity, reverse=True, min_id=0, offset_date=None):
        self.calls.append(min_id)
        for x in self.history.get(entity.id, []):
            if x.id > min_id:
                yield x


async def _nichego():
    return None


def csv_v(put, rows):
    with open(put, "w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows(rows)
    return put


def csv_iz(put):
    with open(put, newline="", encoding="utf-8") as f:
        return list(csv.reader(f))


class IndexTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        self.p = patch.object(app, "DB", self.d / "private" / "indeks.sqlite")
        self.p.start()
        self.c = app.db()

    def tearDown(self):
        self.c.close()
        self.p.stop()
        self.tmp.cleanup()

    # ---------- стадия 1 ----------
    async def test_sobrat_then_dokachka_only_new(self):
        cl = Client()
        lyudey, novyh = await app.sobrat(cl, self.c, 365, 5, 100)
        self.assertEqual((lyudey, novyh), (1, 8))
        cl.history[201] += [m(9, "Созвонимся завтра?", hours_ago=0)]
        cl.dialogs[0].message = cl.history[201][-1]  # Telegram показывает в списке чатов последнее сообщение
        lyudey, novyh = await app.sobrat(cl, self.c, 365, 5, 100)
        self.assertEqual(novyh, 1)
        self.assertEqual(cl.calls[-1], 8)  # второй раз — только новее последнего
        lyudey, novyh = await app.sobrat(cl, self.c, 365, 5, 100)
        self.assertEqual((lyudey, novyh, len(cl.calls)), (1, 0, 2))  # нового нет — за чатом к Telegram не ходим
        stil, tep, yaz, fmt = self.c.execute("select stil, teplota, yazyk, format from people where id=201").fetchone()
        self.assertIn("на «ты»", stil)
        self.assertEqual(tep, "тёплый")
        self.assertEqual(yaz, "русский")
        self.assertIn("знаков", fmt)

    async def test_sobrat_ostanavlivaetsya_na_granice_chata_i_prodolzhaet(self):
        cl = Client()
        cl.history[204] = [m(i, hours_ago=50 - i) for i in range(1, 7)]
        cl.dialogs.append(Dialog(204, "Борис", cl.history[204][-1]))
        cl.hvatit = lambda: len(cl.calls) >= 1  # сторож: дневной запас выбран после первого чата
        self.assertEqual(await app.sobrat(cl, self.c, 365, 5, 100), (1, 8))
        self.assertIsNone(self.c.execute("select 1 from people where id=204").fetchone())
        cl.hvatit = lambda: False  # следующие сутки
        self.assertEqual(await app.sobrat(cl, self.c, 365, 5, 100), (2, 6))  # Анна уже в базе, докачан только Борис
        self.assertEqual(len(cl.calls), 2)

    async def test_obryv_na_seredine_chata_sohranyaet_prochitannoe(self):
        cl = Client()

        async def obryv(entity, reverse=True, min_id=0, offset_date=None):
            for x in cl.history[201][:6]:
                yield x
            raise RuntimeError("сторож: притормози")

        cl.iter_messages = obryv
        with self.assertRaises(RuntimeError):
            await app.sobrat(cl, self.c, 365, 5, 100)
        last_id, msgs, stil = self.c.execute("select last_id, msgs, stil from people where id=201").fetchone()
        self.assertEqual((last_id, msgs), (6, 6))
        self.assertIsNotNone(stil)  # карточка пересчитана по прочитанному

    def test_skan_bez_storozha_ne_zapuskaetsya(self):
        with patch.object(app, "TG", self.d / "telegram"):
            with self.assertRaises(SystemExit) as e:
                app.nayti_storozha()
        self.assertIn("nagruzka.py", str(e.exception))

    def storozh_v_papke(self):
        """Папка Telegram со сторожем из соседнего скила и давним входом. Нет соседа — тест пропускается."""
        storozh = Path(__file__).resolve().parents[2] / "podklyuchit-telegram" / "scripts" / "nagruzka.py"
        if not storozh.exists():
            self.skipTest("скил podklyuchit-telegram не лежит рядом")
        tg = self.d / "telegram"
        tg.mkdir()
        (tg / "nagruzka.py").write_text(storozh.read_text(encoding="utf-8"), encoding="utf-8")
        p = patch.object(app, "TG", tg)
        p.start()
        self.addCleanup(p.stop)
        n = app.nayti_storozha()
        p = patch.object(app, "nayti_storozha", lambda: n)  # один и тот же модуль в тесте и в run
        p.start()
        self.addCleanup(p.stop)
        n.otmetit_vhod(tg, n.seychas() - timedelta(days=30))
        return tg, n

    def pod(self, n, na_chat=1):
        """Подставной клиент под сторожем: чтение одного чата стоит na_chat обращений."""
        class Pod(n.Schetchik, Client):
            async def connect(self): pass
            async def disconnect(self): pass
            async def is_user_authorized(self): return True

            async def iter_messages(self, entity, **kwargs):
                self.zaprosov += na_chat
                async for x in Client.iter_messages(self, entity, **kwargs):
                    yield x

        cl = Pod()
        cl.history[204] = [m(i, hours_ago=50 - i) for i in range(1, 7)]
        cl.dialogs.append(Dialog(204, "Борис", cl.history[204][-1]))
        return cl

    SOBRAT = SimpleNamespace(command="sobrat", dney=365, min=5, limit=500)

    async def test_skan_v_pervye_sutki_posle_vhoda_zakryt(self):
        tg, n = self.storozh_v_papke()
        n.otmetit_vhod(tg, n.seychas() - timedelta(hours=3))
        with patch.object(app, "klient", side_effect=AssertionError("в сеть нельзя")):
            with self.assertRaises(SystemExit) as e:
                await app.run(self.SOBRAT)
            self.assertIn("первые сутки", str(e.exception))
            self.assertFalse((tg / ".telegram.lock").exists())
            n.otmetit_vhod(tg, n.seychas() - timedelta(days=30))
            n.zapisat_otkaz(tg, type("FloodWaitError", (Exception,), {"seconds": 900})(), "read")
            with self.assertRaises(SystemExit) as e:  # Telegram назвал срок — скан не выходит в сеть
                await app.run(self.SOBRAT)
            self.assertIn("просил подождать", str(e.exception))

    async def test_skan_pod_storozhem_idet_porciyami(self):
        tg, n = self.storozh_v_papke()
        sost = n.prochitat(tg)
        sost["seansy"] = [[n.iso(n.seychas() - timedelta(hours=2)), 3000 - n.MIN_SKAN, "read"]]  # запаса хватит на один чат
        n.sohranit(tg, sost)
        cl = self.pod(n, na_chat=n.MIN_SKAN)
        vyvod = []
        with patch.object(app, "klient", lambda storozh=None: cl), patch.object(n.asyncio, "sleep", lambda sek: _nichego()), \
                patch("builtins.print", lambda *a, **k: vyvod.append(" ".join(map(str, a)))):
            await app.run(self.SOBRAT)
        self.assertIn("Порция готова", "\n".join(vyvod))  # первый чат прочитан, на втором сторож остановил
        self.assertIsNone(self.c.execute("select 1 from people where id=204").fetchone())
        self.assertFalse((tg / ".telegram.lock").exists())
        self.assertEqual(n.prochitat(tg)["seansy"][-1][1:], [n.MIN_SKAN, "sobrat"])  # расход попал в общий журнал
        with self.assertRaises(SystemExit) as e:  # сразу повторить нельзя: запас выбран
            await app.run(self.SOBRAT)
        self.assertIn("Притормози", str(e.exception))

    async def test_sboy_uborki_ne_ostavlyaet_zamok(self):
        tg, n = self.storozh_v_papke()
        cl = self.pod(n)
        with patch.object(app, "klient", lambda storozh=None: cl), patch.object(n.asyncio, "sleep", lambda sek: _nichego()), \
                patch.object(n, "zakonchit", side_effect=OSError("диск полон")), patch("builtins.print", lambda *a, **k: None):
            with self.assertRaises(OSError):
                await app.run(self.SOBRAT)
        self.assertFalse((tg / ".telegram.lock").exists())  # иначе оба скила ответят «сессия занята»

    async def test_chat_pri_obryve_ne_obeshchaet_dokachku(self):
        tg, n = self.storozh_v_papke()
        cl = self.pod(n)

        async def obryv(*a, **k):
            raise n.Pritormozi("Притормози: запуск вышел за дневной запас.")

        with patch.object(app, "klient", lambda storozh=None: cl), patch.object(app, "iz_chata", obryv):
            with self.assertRaises(SystemExit) as e:
                await app.run(SimpleNamespace(command="chat", chat="Клуб", soobshcheniy=3000, vse=False))
        self.assertIn("в базу ничего не записано", str(e.exception))
        self.assertNotIn("докачает", str(e.exception))

    async def test_sluzhebnoe_poslednee_soobshchenie_ne_kachaetsya_zanovo(self):
        cl = Client()
        zvonok = m(9, "", hours_ago=0, action=type("MessageActionPhoneCall", (), {})())
        cl.history[201].append(zvonok)
        cl.dialogs[0].message = zvonok  # переписка кончается звонком
        for _ in range(3):
            await app.sobrat(cl, self.c, 365, 5, 100)
        zvonki, last_id = self.c.execute("select zvonki, last_id from people where id=201").fetchone()
        self.assertEqual((zvonki, last_id, len(cl.calls)), (1, 9, 1))  # звонок посчитан один раз, за чатом сходили один раз

    def test_stil_reads_voice_and_formal(self):
        t = (NOW - timedelta(days=1)).isoformat()
        rows = [(t, 1, 30, 0, "Добрый день, вам удобно?"), (t, 0, 0, 1, ""), (t, 0, 0, 1, ""), (t, 0, 20, 0, "Да, вам спасибо")]
        s = app.stil(rows)
        self.assertIn("на «вы»", s)
        self.assertIn("голосом", s)

    def test_yazyk_i_format_dlya_otklika(self):
        t0 = NOW - timedelta(days=2)

        def r(minutes, out, text, golos=0):
            return ((t0 + timedelta(minutes=minutes)).isoformat(), out, len(text), golos, text)
        rows = [r(0, 1, "Hi! Can we talk tomorrow?"), r(5, 0, "Sure, let's do it"), r(6, 0, "Morning works for me"),
                r(7, 0, "Send the link https://zoom.us/j/1 please"), r(60, 1, "Great"), r(70, 0, "Thanks a lot, see you"),
                r(71, 0, "One more thing about the deck")]
        self.assertEqual(app.yazyk(rows), "английский")
        f = app.format_soobshcheniya(rows)
        self.assertIn("до ~50 знаков", f)
        self.assertIn("серией", f)
        ru = [r(0, 0, "Добрый день! Посмотрел вашу презентацию, есть пара вопросов по срокам и бюджету пилота."),
              r(90, 1, "Да, давайте обсудим"), r(200, 0, "Отлично, тогда в четверг в 15:00 удобно?")]
        self.assertEqual(app.yazyk(ru), "русский")
        self.assertIn("одним сообщением", app.format_soobshcheniya(ru))

    def test_teplota_levels(self):
        self.assertEqual(app.teplota(NOW.isoformat(), 1, 1, 10), "горячий")
        self.assertEqual(app.teplota((NOW - timedelta(days=90)).isoformat(), 1, 0, 20), "оживить")

    def test_staraya_baza_poluchaet_novye_polya(self):
        put = self.d / "old" / "indeks.sqlite"
        put.parent.mkdir()
        old = sqlite3.connect(put)
        old.execute("create table people(id integer primary key, name text, username text, last_id integer default 0, "
                    "msgs integer default 0, first_at text, last_at text, last_out integer, zvonki integer default 0, "
                    "teplota text, stil text, kompaniya text, rol text, chem_polezen text, zametki text, updated_at text)")
        old.execute("insert into people(id, name) values(7, 'Пётр')")
        old.commit()
        old.close()
        with patch.object(app, "DB", put):
            c = app.db()
            est = {r[1] for r in c.execute("pragma table_info(people)")}
            tablicy = {r[0] for r in c.execute("select name from sqlite_master where type='table'")}
            c.close()
        self.assertTrue(set(app.TEKST_KOLONKI + app.CHISLO_KOLONKI) <= est)
        self.assertTrue({"sostoyaniya", "produkty", "pod_produkt", "razmetka"} <= tablicy)

    async def test_zapolnit_sostoyanie_data_i_vneshnyaya_bez_imen(self):
        self.c.execute("insert into people(id, name, username, teplota, stil) values(5,'Мария','masha','горячий','на «ты»')")
        self.c.commit()
        await app.run(app.cli(["zapolnit", "--kto", "masha", "--kompaniya", "Логистика Плюс", "--napravlenie",
                               "доставка для маркетплейсов", "--masshtab", "40 млн в год", "--svyaz", "созванивались в сентябре",
                               "--profil", "https://t.me/masha", "--sost", "факт", "--data", "2026-10-01"]))
        await app.run(app.cli(["istochnik", "--kto", "5", "--tip", "сохранённая переписка", "--ssylka", "private/masha.md"]))
        c = app.db()
        self.assertEqual(c.execute("select sost, data from sostoyaniya where chat_id=5 and pole='napravlenie'").fetchone(),
                         ("факт", "2026-10-01"))
        self.assertEqual(c.execute("select data_svedeniy from people where id=5").fetchone()[0], "2026-10-01")
        rows = app.sovpadeniya(c, "Ищем партнёров по доставке для маркетплейсов", 5)
        c.close()
        self.assertEqual([r[1]["name"] for r in rows], ["Мария"])
        txt = app.zapisat(rows, self.d / "m.csv", False).read_text(encoding="utf-8")
        for chuzhoe in ("Мария", "masha", "t.me", "созванивались", "40 млн"):
            self.assertNotIn(chuzhoe, txt)
        self.assertIn("доставка для маркетплейсов", txt)
        with self.assertRaises(SystemExit):
            app.vneshnie_polya("kompaniya,profil")
        vnutr = app.zapisat(rows, self.d / "v.csv", True, istochniki={5: "сохранённая переписка: private/masha.md"})
        self.assertIn("private/masha.md", vnutr.read_text(encoding="utf-8"))

    async def test_holodnye_iz_chata_tolko_po_interesu(self):
        lena = SimpleNamespace(id=301, first_name="Лена", last_name="Котова", username="lena_k", bot=False)
        bot = SimpleNamespace(id=302, first_name="Бот", last_name=None, username="x_bot", bot=True)
        msgs = [SimpleNamespace(out=False, sender=lena, message="Делаем логистику для маркетплейсов, ищем партнёров"),
                SimpleNamespace(out=False, sender=bot, message="реклама"),
                SimpleNamespace(out=True, sender=None, message="моё")]
        chat = SimpleNamespace(id=-100, name="Клуб фаундеров", is_user=False, entity=SimpleNamespace(id=100, username=None))

        class ChatClient:
            async def iter_dialogs(self, limit=None):
                yield chat

            async def iter_messages(self, entity, limit=None):
                for x in msgs:
                    yield x
        novyh, vsego = await app.iz_chata(ChatClient(), self.c, "клуб фаундеров", 100)
        self.assertEqual((novyh, vsego), (1, 1))
        self.c.execute("update people set napravlenie='логистика для маркетплейсов' where id=301")
        self.c.commit()
        self.assertEqual(app.sovpadeniya(self.c, "логистика маркетплейсов", 5), [])
        self.c.execute("update people set interes=1 where id=301")
        self.assertEqual([r[1]["name"] for r in app.sovpadeniya(self.c, "логистика маркетплейсов", 5)], ["Лена Котова"])

    # ---------- стадии 2 и 3: под продукт ----------
    async def test_produkt_ocenit_celevye_i_vneshnyaya(self):
        self.c.execute("insert into people(id, name, username, teplota, kompaniya, rol, napravlenie) values"
                       "(11,'Олег','oleg','тёплый','Школы Онлайн','CEO','продюсирование онлайн-школ, 40 школ в портфеле')")
        self.c.execute("insert into people(id, name, username, teplota, napravlenie) values(12,'Ира','ira','оживить','кофейня')")
        self.c.commit()
        intro = self.d / "moe_intro.md"
        intro.write_text("Оффер: ИИ-ассистент для онлайн-школ. Для кого: владельцы онлайн-школ. Кто нужен: продюсеры школ.",
                         encoding="utf-8")
        await app.run(app.cli(["produkt", "--kod", "iskra", "--nazvanie", "Искра", "--chey", "мой", "--lider", "я",
                               "--intro", str(intro)]))
        await app.run(app.cli(["pod_produkt", "--produkt", "iskra"]))
        await app.run(app.cli(["ocenit", "--kto", "oleg", "--produkt", "iskra", "--kandidat", "да", "--segment", "A",
                               "--partner", "маяк", "--kakie", "40 онлайн-школ", "--pochemu", "за: портфель школ…",
                               "--status", "не успел дать оффер — следующий шаг: созвон", "--zachem", "даст выход на школы"]))
        with self.assertRaises(SystemExit):
            await app.run(app.cli(["ocenit", "--kto", "oleg", "--produkt", "iskra", "--partner", "друг"]))
        rows = app.celevye(self.c, "iskra")
        self.assertEqual([(r["name"], r["segment"], r["partner"]) for r in rows], [("Олег", "A", "маяк")])
        out = self.d / "vneshnyaya.csv"
        await app.run(app.cli(["vneshnyaya", "--produkt", "iskra", "--out", str(out)]))
        txt = out.read_text(encoding="utf-8")
        self.assertNotIn("Олег", txt)
        self.assertNotIn("oleg", txt)
        self.assertNotIn("портфель школ", txt)  # 3 за и 3 против — внутреннее
        self.assertIn("Школы Онлайн", txt)
        self.assertIn("даст выход на школы", txt)

    # ---------- чужая база ----------
    async def test_chuzhaya_baza_import_kopiya_razmetka(self):
        self.c.execute("insert into people(id, name, username, kompaniya) values(201,'Анна','anna_t', 'Своя компания')")
        self.c.commit()
        baza = csv_v(self.d / "denis.csv", [
            ["ФИО", "Название компании", "Должность", "Telegram", "Чем занимается", "Дата обновления", "Дата рождения", "Хобби"],
            ["Пётр Иванов", "Ритейл Групп", "директор по маркетингу", "petr_test", "сеть магазинов", "2026-09-15", "1980-01-01", "гольф"],
            ["Анна", "Чужая компания", "CEO", "https://t.me/anna_t", "финтех", "", "", ""],
            ["", "", "", "", "", "", "", ""],
        ])
        novyh, obnovleno, karta = app.import_bazy(self.c, baza, "Денис", data="2026-10-24")
        self.assertEqual((novyh, obnovleno), (1, 1))
        self.assertEqual(karta["Название компании"], "kompaniya")
        self.assertNotIn("Дата рождения", karta)
        pid, vl, nap, zam, data = self.c.execute(
            "select id, vladelec, napravlenie, zametki, data_svedeniy from people where username='petr_test'").fetchone()
        self.assertLess(pid, 0)
        self.assertEqual(vl, "Денис")
        self.assertEqual(data, "2026-09-15")
        self.assertIn("Хобби: гольф", zam)
        self.assertIn("Дата рождения: 1980-01-01", zam)
        self.assertEqual(self.c.execute("select sost from sostoyaniya where chat_id=? and pole='napravlenie'", (pid,)).fetchone()[0],
                         "со слов передавшего")
        anna = self.c.execute("select kompaniya, napravlenie, vladelec from people where id=201").fetchone()
        self.assertEqual(anna, ("Своя компания", "финтех", None))  # своё не перезаписали, пустое дописали, человек остался твоим
        kopiya = self.d / "dlya_denisa.csv"
        _, n = app.dlya_partnera(self.c, "Денис", kopiya)
        self.assertEqual(n, 2)
        rows = csv_iz(kopiya)
        zag = rows[0]
        self.assertTrue(any(z.startswith("Прислушается к тебе") for z in zag))
        self.assertTrue(any(z.startswith("Доступ через тебя") for z in zag))
        for vnutr in ("Теплота", "Заметки", "Сегмент", "Почему"):
            self.assertFalse(any(vnutr in z for z in zag), vnutr)
        i_kod, i_pr, i_do = zag.index("Код"), next(i for i, z in enumerate(zag) if z.startswith("Прислушается")), \
            next(i for i, z in enumerate(zag) if z.startswith("Доступ через тебя"))
        for r in rows[1:]:  # Пётр — только его, «не трогать»; Анна — и наша, тоже «не трогать»
            r[i_pr], r[i_do] = ("3", "не берусь — не трогать")
        csv_v(kopiya, rows)
        prinyato, ne_trogat = app.prinyat_razmetku(self.c, kopiya, "Денис")
        self.assertEqual((prinyato, ne_trogat), (2, 1))
        self.assertEqual(app.sovpadeniya(self.c, "сеть магазинов", 5), [])  # его человек выпал из выборок
        self.assertEqual([r[1]["name"] for r in app.sovpadeniya(self.c, "финтех", 5)], ["Анна"])  # наша связь осталась
        for r in rows[1:]:
            if r[i_kod] == "201":
                r[i_pr], r[i_do] = "8", "представлю лично на встрече"
        csv_v(kopiya, rows)
        app.prinyat_razmetku(self.c, kopiya, "Денис")
        self.assertEqual(self.c.execute("select prislushaetsya, dostup from razmetka where chat_id=201").fetchone(),
                         (8, "представлю лично на встрече"))
        rows[1][i_do] = "что-то своё"
        csv_v(kopiya, rows)
        with self.assertRaises(SystemExit):
            app.prinyat_razmetku(self.c, kopiya, "Денис")


    # ---------- стадия 1 без Telegram: выгрузка и расшифровки ----------
    def test_iz_vygruzki_dokachka_i_zvonki(self):
        papka = self.d / "dialogi"
        papka.mkdir()
        d = (NOW - timedelta(days=2)).strftime("%Y-%m-%d %H:%M")
        stroki = [{"id": i, "d": d, ("ya" if i % 2 else "on"): 1, "t": "Привет, как ты?"} for i in range(1, 7)]
        stroki.append({"id": 7, "d": d, "on": 1, "t": "", "zvonok_sek": 300})
        (papka / "501.jsonl").write_text("\n".join(app.json.dumps(x, ensure_ascii=False) for x in stroki), encoding="utf-8")
        (papka / "502.jsonl").write_text(app.json.dumps({"id": 1, "d": d, "on": 1, "t": "ок"}), encoding="utf-8")
        lyudey, novyh = app.iz_vygruzki(self.c, papka, 5, {"501": {"imya": "Анна Петрова", "nik": "anna_p"}})
        self.assertEqual((lyudey, novyh), (1, 6))  # 502 — меньше 5 сообщений, карточки нет
        name, nik, zv, tep = self.c.execute("select name, username, zvonki, teplota from people where id=501").fetchone()
        self.assertEqual((name, nik, zv, tep), ("Анна Петрова", "anna_p", 1, "горячий"))  # звонок → горячий
        lyudey, novyh = app.iz_vygruzki(self.c, papka, 5)
        self.assertEqual(novyh, 0)  # повторно ничего не читаем

    def test_rasshifrovki_po_niku_i_imeni(self):
        self.c.execute("insert into people(id, name, username, msgs) values(601, 'Сергей Громов Партнёр', 'sgromov', 0)")
        self.c.execute("insert into people(id, name, username, msgs) values(602, 'Анна Петрова', null, 0)")
        self.c.execute("insert into people(id, name, username, msgs) values(603, 'Анна Петрова Маркетинг', null, 0)")
        self.c.commit()
        papka = self.d / "zoom"
        papka.mkdir()
        (papka / "zoom_2026-10-20_vstrecha_partner.vtt").write_text(
            "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\nВладелец Индекса " + AT + "vladelec_i (Хаб): привет\n\n"
            "2\n00:00:03.000 --> 00:00:04.000\nСергей Г " + AT + "sgromov (Партнёр): привет\n\n"
            "3\n00:00:05.000 --> 00:00:06.000\nНовый Человек " + AT + "novyi_chel (Хаб): добрый день\n\n"
            "4\n00:00:07.000 --> 00:00:08.000\nАнна Петрова: здравствуйте\n\n"
            "5\n00:00:09.000 --> 00:00:10.000\nНапример: это не человек\n", encoding="utf-8")
        faylov, svyazey, novyh, top = app.rasshifrovki(self.c, papka, [AT + "vladelec_i", "Владелец Индекса"])
        self.assertEqual((faylov, svyazey, novyh), (1, 2, 1))  # Сергей по нику + новый с ником; себя не считаем
        self.assertEqual(self.c.execute("select sozvony, teplota from people where id=601").fetchone(), (1, "горячий"))
        self.assertIn("Анна Петрова", dict(top))  # 2 совпадения по имени — не угадываем
        self.assertIsNone(self.c.execute("select 1 from people where name like 'Например%'").fetchone())
        faylov, svyazey, novyh, top = app.rasshifrovki(self.c, papka, [AT + "vladelec_i"])
        self.assertEqual((svyazey, novyh), (0, 0))  # повторный проход не удваивает созвоны

    def test_po_imeni_translit_i_umenshitelnye(self):
        self.c.execute("insert into people(id, name) values(701, 'Дима Судаков')")
        self.c.execute("insert into people(id, name) values(702, 'Александр Савицкий')")
        self.c.execute("insert into people(id, name) values(703, 'Елена Судакова')")
        idx = app.indeks_imen(self.c)
        self.assertEqual(app.po_imeni(idx, app.tokeny("Dmitry Sudakov")), 701)
        self.assertEqual(app.po_imeni(idx, app.tokeny("Дмитрий Судаков")), 701)
        self.assertEqual(app.po_imeni(idx, app.tokeny("Aleksandr Savitckii")), 702)
        self.assertIsNone(app.po_imeni(idx, app.tokeny("Михаил Судаков")))  # имя не сходится — не угадываем
        self.c.execute("insert into people(id, name) values(704, 'Полина Насекина')")
        idx = app.indeks_imen(self.c)
        self.assertIsNone(app.po_imeni(idx, app.tokeny("Елена Насекина")))  # однофамилица — не она

    def test_plotnoe_zapolnenie_ochered_pachka_kartochki(self):
        self.c.execute("insert into people(id, name, username, msgs) values(801, 'Олег Петров', 'oleg_p', 3)")
        self.c.execute("insert into people(id, name, username, msgs, zvonki, posl_zvonok) values(802, 'Ира', null, 2, 1, '2026-05-01')")
        self.c.execute("insert into people(id, name, msgs, zvonki) values(803, 'Мама', 2, 4)")
        self.c.execute("insert into msgs values(801, 1, '2026-10-01T10:00', 0, 80, 0, 'Делаем сервис доставки, выручка 40 млн в год, ищем партнёров в ритейле')")
        papka = self.d / "zoom"
        papka.mkdir()
        (papka / "zoom_2026-10-20_vstrecha.vtt").write_text(
            "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.000\nОлег П " + AT + "oleg_p (Доставка): Меня зовут Олег, у нас сервис "
            "доставки для ресторанов, 300 клиентов, ищем выход на сети.\n\n2\n00:00:03.000 --> 00:00:04.000\n"
            "Владелец " + AT + "vladelec_i: понял\n", encoding="utf-8")
        app.rasshifrovki(self.c, papka, [AT + "vladelec_i"])
        app.isklyuchit(self.c, 803, "личное")
        q = app.ochered(self.c)
        self.assertEqual([r[2] for r in q], [801, 802])  # сначала с расшифровкой; исключённого нет
        self.assertEqual(q[0][1], "2026-10-20")
        tekst, n, ostalos = app.pachka(self.c, 1)
        self.assertEqual((n, ostalos), (1, 1))
        self.assertIn("300 клиентов", tekst)  # его речь из расшифровки
        self.assertIn("40 млн", tekst)  # его сообщение в личке
        self.assertNotIn("понял", tekst)  # реплики владельца не берём
        gotovo, isk, net = app.zapolnit_pachkoy(self.c, [
            {"id": 801, "data": "2026-10-20", "otkuda": "расшифровка созвона", "kompaniya": "Доставка",
             "napravlenie": "Сервис доставки для ресторанов", "kto_nuzhen": "Выход на сети", "gipoteza": ["kto_nuzhen"]},
            {"id": 802, "otkuda": "личка — деловых фактов нет"}, {"kto": "nikto"}])
        self.assertEqual((gotovo, isk, net), (2, 0, ["nikto"]))
        self.assertEqual(app.ochered(self.c), [])  # заполненные с очереди сняты — после сжатия окна идём дальше
        sost = dict(self.c.execute("select pole, sost from sostoyaniya where chat_id=801"))
        self.assertEqual((sost["napravlenie"], sost["kto_nuzhen"]), ("факт", "гипотеза"))
        self.assertEqual(self.c.execute("select tip from istochniki where chat_id=801 and tip like 'заполнено%'").fetchone()[0],
                         "заполнено по расшифровке")

    def test_socaktiv_bez_imen_i_utechki(self):
        self.c.execute("insert into people(id, name, username, sozvony, kompaniya, rol, napravlenie, keysy) values("
                       "901, 'Анна Смирнова', 'anna_s', 1, 'Анна Смирнова', 'основатель', "
                       "'Школа английского для IT, работаем с Иван Петров и " + AT + "partner_x', 'Выручка 12 млн ₽')")
        self.c.execute("insert into people(id, name, sozvony, napravlenie) values(902, 'Пётр Иванов', 1, 'Фонд, www.fond.ru')")
        self.c.execute("insert into people(id, name, sozvony) values(903, 'Без дела', 1)")
        self.c.execute("insert into people(id, name, zvonki, napravlenie, isklyuchen) values(904, 'Жена', 3, 'Семья', 'личное')")
        self.c.execute("insert into istochniki values(901, 'созвон', 'zoom_2026-10-01.vtt', 'созвон 2026-10-01, реплик 5', '')")
        self.c.execute("insert into istochniki values(902, 'созвон', 'zoom_2026-10-15.vtt', 'созвон 2026-10-15, реплик 5', '')")
        app.otmetit(self.c, 901, ["napravlenie"], "факт", "2026-10-01")
        rows, pusto, po_slovam, vsego = app.socaktiv(self.c)
        self.assertEqual((len(rows), pusto, po_slovam, vsego), (2, 1, 1, 3))  # жена исключена, «без дела» не вошёл
        self.assertEqual(rows[0][7], "2026-10-15")  # свежий созвон сверху
        anna = rows[1]
        self.assertEqual(anna[0], "основатель")  # его имя в поле «компания» — это не компания
        self.assertTrue(anna[1].startswith("● Школа английского"))
        vse = " ".join(" ".join(r) for r in rows)
        for chto in ("Иван Петров", AT + "partner_x", "www.", "Смирнова"):
            self.assertNotIn(chto, vse)
        self.assertEqual(app.utechki(self.c, rows), [])
        self.assertTrue(app.utechki(self.c, [["работаем со Смирнова", "@nik", "+7 900 " + "123-45-67"]]))
        rows, *_ = app.socaktiv(self.c, dney=10_000)
        self.assertEqual(len(rows), 2)
        self.assertEqual(app.bez_imen("Аминов Егор. Продюсер."), "[имя]. Продюсер.")
        self.assertEqual(app.bez_imen("Технопарк Сколково и Газпромбанк"), "Технопарк Сколково и Газпромбанк")
        self.assertEqual(app.bez_imen("Показатели не выделены"), "")


if __name__ == "__main__":
    unittest.main()
