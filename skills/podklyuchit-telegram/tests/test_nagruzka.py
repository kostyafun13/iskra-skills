"""Изолированная проверка сторожа нагрузки. Ни сеть, ни настоящая сессия не используются."""
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from telethon.client.users import UserMethods
from telethon.errors import (ChannelPrivateError, FloodPremiumWaitError, FloodWaitError, PeerFloodError,
                             SessionRevokedError, SlowModeWaitError)
from telethon.tl.types import User

scripts = Path(__file__).resolve().parents[1] / "scripts"


def zagruzit(imya):
    spec = importlib.util.spec_from_file_location(imya, scripts / (imya + ".py"))
    modul = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modul)
    return modul


app = zagruzit("telegram_app")
n = app.nagruzka
T0 = datetime(2030, 1, 10, 12, 0, tzinfo=timezone.utc)  # момент входа в тестах
PROBY = n.STUPENI[0][1]  # дневной запас первых суток


def cherez(chasov):
    return T0 + timedelta(hours=chasov)


class Papka(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        n.otmetit_vhod(self.root, T0)

    def tearDown(self):
        self.tmp.cleanup()

    def zapusk(self, kogda, skolko, komanda="read"):
        sost = n.prochitat(self.root)
        sost.setdefault("seansy", []).append([n.iso(kogda), skolko, komanda])
        n.sohranit(self.root, sost)


class StupeniTests(Papka):
    def test_stupeni_rastut_s_vozrastom_vhoda(self):
        predely = [n.svodka(self.root, cherez(ch))["predel"] for ch in (1, 30, 50, 100)]
        self.assertEqual(predely, [150, 600, 1500, 3000])
        self.assertTrue(n.svodka(self.root, cherez(50))["svezhiy"])
        self.assertFalse(n.svodka(self.root, cherez(100))["svezhiy"])

    def test_skan_zakryt_v_pervye_sutki_a_proby_otkryty(self):
        with self.assertRaises(SystemExit) as e:
            n.proverit(self.root, "skan", cherez(3))
        self.assertIn("первые сутки", str(e.exception))
        self.assertEqual(n.proverit(self.root, "chtenie", cherez(3))["ostatok"], PROBY)
        self.assertEqual(n.proverit(self.root, "skan", cherez(25))["ostatok"], 600)

    def test_uchastniki_chata_tolko_cherez_troe_sutok(self):
        with self.assertRaises(SystemExit) as e:
            n.proverit(self.root, "uchastniki", cherez(30))
        self.assertIn("Список участников", str(e.exception))
        n.proverit(self.root, "uchastniki", cherez(80))

    def test_zapas_vybran_chtenie_stoit_otpravka_idet(self):
        self.zapusk(cherez(2), PROBY)
        with self.assertRaises(SystemExit) as e:
            n.proverit(self.root, "chtenie", cherez(3))
        self.assertIn("Притормози", str(e.exception))
        n.proverit(self.root, "otpravka", cherez(3))  # отправка по поручению дневным запасом не закрывается
        n.proverit(self.root, "sluzhba", cherez(3))

    def test_mesto_poyavlyaetsya_s_novoy_stupenyu_i_kogda_zapusk_uhodit_iz_sutok(self):
        self.zapusk(cherez(2), PROBY)
        self.assertEqual(n.svodka(self.root, cherez(3))["mozhno"], cherez(24) + timedelta(seconds=1))  # вторые сутки: предел 600
        self.zapusk(cherez(100), 3000)
        self.assertEqual(n.svodka(self.root, cherez(101))["mozhno"], cherez(124) + timedelta(seconds=1))
        n.proverit(self.root, "chtenie", cherez(125))

    def test_skan_ne_nachinaetsya_s_malym_ostatkom(self):
        self.zapusk(cherez(30), 600 - n.MIN_SKAN + 1)  # в запасе меньше, чем нужно скану на старт
        with self.assertRaises(SystemExit) as e:
            n.proverit(self.root, "skan", cherez(31))
        self.assertIn("Скан продолжится после", str(e.exception))
        n.proverit(self.root, "chtenie", cherez(31))  # обычное чтение на остаток идёт
        sv = n.svodka(self.root, cherez(31))
        self.assertEqual(sv["mozhno_skan"], cherez(48) + timedelta(seconds=1))  # третьи сутки: предел 1500
        n.proverit(self.root, "skan", sv["mozhno_skan"])

    def test_novyy_vhod_ne_nasleduet_raskhod_starogo(self):
        self.zapusk(cherez(100), 800)
        n.otmetit_vhod(self.root, cherez(101))  # вход закрылся, владелец вошёл заново
        self.assertEqual(n.proverit(self.root, "chtenie", cherez(102))["ostatok"], PROBY)

    def test_davniy_vhod_podtverzhdaet_vladelets_no_ne_posle_login(self):
        self.assertIn("менять её нельзя", n.podtverdit_davniy_vhod(self.root, cherez(2)))  # дату отметил login
        self.assertEqual(n.svodka(self.root, cherez(2))["predel"], PROBY)
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(SystemExit) as e:  # ни отметки, ни файла входа: считаем свежим и подсказываем выход
                n.proverit(d, "skan", T0)
            self.assertIn("--vhod-davniy", str(e.exception))
            self.assertIn("со слов владельца", n.podtverdit_davniy_vhod(d, T0))
            self.assertEqual(n.proverit(d, "uchastniki", T0)["predel"], 3000)

    def test_vhod_bez_otmetki_schitaetsya_ne_pozzhe_seychas(self):
        with tempfile.TemporaryDirectory() as d:
            sv = n.svodka(d, T0)  # ни состояния, ни файла входа
            self.assertEqual(sv["vhod"], T0)
            self.assertIn("свежим", sv["vhod_otkuda"])
            (Path(d) / "personal_telegram.session").write_bytes(b"")
            os.remove(n.put(d))
            self.assertLessEqual(n.svodka(d)["vhod"], n.seychas())

    def test_isporchennyy_fayl_ne_ronyaet_rabotu(self):
        n.put(self.root).write_text("{не json", encoding="utf-8")
        self.assertEqual(n.prochitat(self.root), {})


class OtkazTests(Papka):
    def test_telegram_nazval_srok_do_nego_ne_hodim_sovsem(self):
        tekst = n.zapisat_otkaz(self.root, FloodWaitError(request=None, capture=300), "read", cherez(30))
        self.assertIn("просил подождать", tekst)
        for vid in ("sluzhba", "otpravka", "chtenie", "skan"):
            with self.assertRaises(SystemExit):
                n.proverit(self.root, vid, cherez(30) + timedelta(seconds=200))
        self.assertIn("раньше", n.snyat_stop(self.root, cherez(30) + timedelta(seconds=200)))
        n.proverit(self.root, "chtenie", cherez(30) + timedelta(seconds=400))  # срок прошёл — стоп снимается сам

    def test_otkaz_urovnya_akkaunta_zhdet_slova_vladeltsa(self):
        tekst = n.zapisat_otkaz(self.root, SessionRevokedError(request=None), "sobrat", cherez(30))
        self.assertIn("до решения владельца", tekst)
        n.proverit(self.root, "sluzhba", cherez(200))  # status и login владельцу доступны
        for vid in ("otpravka", "chtenie", "skan"):
            with self.assertRaises(SystemExit):
                n.proverit(self.root, vid, cherez(200))
        self.assertIn("Стоп снят", n.snyat_stop(self.root, cherez(200)))
        n.proverit(self.root, "chtenie", cherez(200))

    def test_stop_do_slova_vladeltsa_ne_zatiraetsya_srokom(self):
        n.zapisat_otkaz(self.root, PeerFloodError(request=None), "send", cherez(30))
        # Владелец запускает status, тот получает «подождите 30 секунд».
        tekst = n.zapisat_otkaz(self.root, FloodWaitError(request=None, capture=30), "status", cherez(31))
        self.assertIn("просил подождать", tekst)
        with self.assertRaises(SystemExit):
            n.proverit(self.root, "sluzhba", cherez(31) + timedelta(seconds=10))
        posle = cherez(31) + timedelta(seconds=200)  # срок прошёл, а решение владельца всё ещё нужно
        n.proverit(self.root, "sluzhba", posle)
        for vid in ("otpravka", "chtenie", "skan"):
            with self.assertRaises(SystemExit) as e:
                n.proverit(self.root, vid, posle)
            self.assertIn("PeerFloodError", str(e.exception))
        self.assertIn("Стоп снят", n.snyat_stop(self.root, posle))
        n.proverit(self.root, "otpravka", posle)

    def test_dlinnyy_srok_ne_ukorachivaetsya_novym_korotkim(self):
        n.zapisat_otkaz(self.root, FloodWaitError(request=None, capture=3600), "read", cherez(30))
        n.zapisat_otkaz(self.root, FloodWaitError(request=None, capture=30), "status", cherez(30) + timedelta(seconds=5))
        with self.assertRaises(SystemExit):
            n.proverit(self.root, "chtenie", cherez(30) + timedelta(seconds=600))

    def test_medlennyy_rezhim_chata_i_ochered_skachivaniya_ne_stop(self):
        self.assertIsNone(n.zapisat_otkaz(self.root, SlowModeWaitError(request=None, capture=3600), "send", cherez(30)))
        self.assertIsNone(n.zapisat_otkaz(self.root, FloodPremiumWaitError(request=None, capture=5), "download", cherez(30)))
        for vid in ("sluzhba", "otpravka", "chtenie"):
            n.proverit(self.root, vid, cherez(30))

    def test_obychnaya_oshibka_chata_ne_stop(self):
        self.assertIsNone(n.zapisat_otkaz(self.root, ChannelPrivateError(request=None), "read", cherez(30)))
        self.assertIsNone(n.zapisat_otkaz(self.root, ValueError("x"), "read", cherez(30)))
        n.proverit(self.root, "chtenie", cherez(30))


class GetFileRequest:
    """Имя как у запроса части файла в Telethon: сторож узнаёт его по имени класса."""


class GetDifferenceRequest:
    """Имя как у служебного запроса самой библиотеки."""


class Baza:
    def __init__(self):
        self.ushlo = []

    async def _call(self, sender, request, ordered=False, flood_sleep_threshold=None):
        self.ushlo.append(request)
        return "ответ"


class Klient(n.Schetchik, Baza):
    pass


class SchetchikTests(Papka):
    async def test_schitaet_obrashcheniya_bez_chastey_faylov(self):
        k = Klient()
        for zapros in ("a", "b", GetFileRequest(), GetFileRequest(), GetFileRequest()):
            self.assertEqual(await k._call(None, zapros), "ответ")
        self.assertEqual((k.zaprosov, k.chastey_faylov, len(k.ushlo)), (2, 3, 5))

    async def test_pauzy_idut_posle_pervyh_obrashcheniy(self):
        k = Klient()
        k.pauza, k.bez_pauzy = (2.0, 4.0), 5
        spal = []

        async def son(sek):
            spal.append(sek)

        with patch.object(n.asyncio, "sleep", son):
            for _ in range(8):
                await k._call(None, "a")
        self.assertEqual(len(spal), 3)
        self.assertTrue(all(2.0 <= s <= 4.0 for s in spal))

    async def test_potolok_zapuska_ostanavlivaet_do_seti(self):
        k = Klient()
        k.predel = 3
        for _ in range(3):
            await k._call(None, "a")
        with self.assertRaises(n.Pritormozi):
            await k._call(None, "a")
        self.assertEqual(len(k.ushlo), 3)  # четвёртое обращение в Telegram не ушло

    async def test_sluzhebnye_obrashcheniya_ne_obryvayut_i_ne_tormozyat(self):
        k = Klient()
        k.predel, k.pauza, k.bez_pauzy = 1, (2.0, 4.0), 0
        spal = []

        async def son(sek):
            spal.append(sek)

        with patch.object(n.asyncio, "sleep", son):
            await k._call(None, "a")
            for _ in range(3):  # потолок достигнут, но фоновый запрос библиотеки проходит: связь не рвётся
                self.assertEqual(await k._call(None, GetDifferenceRequest()), "ответ")
            with self.assertRaises(n.Pritormozi):
                await k._call(None, "a")
        self.assertEqual((k.zaprosov, len(spal)), (4, 1))

    async def test_otpravka_i_vhod_idut_bez_pauz_i_bez_potolka(self):
        for vid, komanda in (("otpravka", "send"), ("sluzhba", "login")):
            k = Klient()
            n.nachat(self.root, k, n.proverit(self.root, vid, cherez(2)), vid, komanda)
            self.assertEqual((k.pauza, k.predel, k.ostatok), (None, None, None))
        k = Klient()
        n.nachat(self.root, k, n.proverit(self.root, "chtenie", cherez(2)), "chtenie", "read")
        self.assertEqual((k.pauza, k.predel, k.bez_pauzy), ((2.0, 4.0), PROBY + n.ZAPAS, n.BEZ_PAUZY_SVEZHIY))

    async def test_zanyatyy_fayl_ne_rvet_skan(self):
        k = Klient()
        n.nachat(self.root, k, n.proverit(self.root, "chtenie", cherez(2)), "chtenie", "read")
        k.pauza = None
        with patch.object(n, "sohranit", side_effect=PermissionError("файл занят")):
            for _ in range(n.SBROS_KAZHDYE):
                await k._call(None, "a")
        self.assertEqual(k.zaprosov, n.SBROS_KAZHDYE)

    async def test_zapusk_popadaet_v_zhurnal_a_obryv_ne_teryaet_raskhod(self):
        sv = n.proverit(self.root, "skan", cherez(30))
        k = Klient()
        n.nachat(self.root, k, sv, "skan", "sobrat")
        self.assertEqual((k.ostatok, k.predel, k.pauza_chat), (600, 600 + n.ZAPAS, n.PAUZA_CHAT))
        k.pauza = None
        for _ in range(n.SBROS_KAZHDYE):
            await k._call(None, "a")
        self.assertEqual(n.svodka(self.root, cherez(31))["ispolzovano"], n.SBROS_KAZHDYE)  # счёт виден во время скана
        # Запуск оборвался без zakonchit. Следующий запуск расход не теряет.
        k2 = Klient()
        n.nachat(self.root, k2, n.proverit(self.root, "chtenie", cherez(32)), "chtenie", "read")
        await k2._call(None, "a")
        n.zakonchit(self.root, k2, cherez(32))
        sost = n.prochitat(self.root)
        self.assertEqual([x[1:] for x in sost["seansy"]], [[n.SBROS_KAZHDYE, "sobrat"], [1, "read"]])
        self.assertNotIn("tekushchiy", sost)
        n.zakonchit(self.root, Klient(), cherez(60))  # записи старше суток уходят
        self.assertEqual(n.prochitat(self.root)["seansy"], [])

    async def test_skan_ostanavlivaetsya_na_granice_chata(self):
        k = Klient()
        k.ostatok = 2
        self.assertFalse(k.hvatit())
        await k._call(None, "a")
        await k._call(None, "a")
        self.assertTrue(k.hvatit())

    async def test_nastoyashchiy_klient_telethon_idet_cherez_storozha(self):
        """Сторож держится на внутреннем методе Telethon. Новая версия его поменяет — этот тест упадёт первым."""
        k = app.Klient(str(self.root / "proba"), 1, "x", receive_updates=False, request_retries=0, connection_retries=0)
        ushlo = []

        async def baza(self, sender, request, ordered=False, flood_sleep_threshold=None):
            ushlo.append(type(request).__name__)
            return [User(id=1, first_name="Тест")]

        try:
            with patch.object(UserMethods, "_call", baza):
                me = await k.get_me()
        finally:
            k.session.close()
        self.assertEqual((me.first_name, k.zaprosov, ushlo), ("Тест", 1, ["GetUsersRequest"]))


class TekstyTests(Papka):
    def test_otchet_govorit_chto_delat(self):
        t = n.otchet(self.root, cherez(2))
        self.assertIn("пробы", t)
        self.assertIn("закрыт до", t)
        self.assertIn("запас осторожности", t)
        self.zapusk(cherez(99), 2600)
        self.assertIn("притормози", n.otchet(self.root, cherez(100)).lower())

    def test_stroka_posle_komandy(self):
        self.assertIn("только пробы", n.stroka(self.root, cherez(2)))
        self.assertEqual(n.stroka(self.root, cherez(100)), "")  # давний вход, низкая нагрузка — молчим
        self.zapusk(cherez(99), 2600)
        self.assertIn("Притормози", n.stroka(self.root, cherez(100)))


class FakeKlient(n.Schetchik):
    """Вместо TelegramClient: считает созданные клиенты и по заказу отвечает отказом Telegram."""
    sozdano = 0
    vhod_est = True
    otkaz = None

    def __init__(self, *args, **kwargs):
        type(self).sozdano += 1

    async def connect(self): pass
    async def disconnect(self): pass
    async def is_user_authorized(self):
        self.zaprosov += 1  # настоящая проверка входа — одно обращение
        return type(self).vhod_est
    upast_posle_vhoda = False

    async def start(self):
        type(self).vhod_est = True
        if type(self).upast_posle_vhoda:
            raise RuntimeError("сбой сразу после входа")
    async def get_me(self): return User(id=100, first_name="Владелец")

    async def get_entity(self, peer):
        if type(self).otkaz:
            raise type(self).otkaz
        return User(id=200, first_name="Тестовый адресат")

    async def get_messages(self, peer, **kwargs): return []


class RunTests(Papka):
    def setUp(self):
        super().setUp()
        FakeKlient.sozdano, FakeKlient.vhod_est, FakeKlient.otkaz, FakeKlient.upast_posle_vhoda = 0, True, None, False
        self.patchi = [patch.object(app, "ROOT", self.root), patch.object(app, "Klient", FakeKlient),
                       patch.object(app, "load_dotenv", lambda *a, **k: None),
                       patch.dict(os.environ, {"TELEGRAM_API_ID": "1", "TELEGRAM_API_HASH": "x"})]
        for p in self.patchi:
            p.start()

    def tearDown(self):
        for p in self.patchi:
            p.stop()
        super().tearDown()

    def read(self):
        return SimpleNamespace(command="read", chat="200", limit=5, novoe=False, liniya=None, out=str(self.root / "o.json"))

    def staryy_vhod(self):
        n.otmetit_vhod(self.root, n.seychas() - timedelta(days=30))

    async def test_zapas_vybran_komanda_ne_vyhodit_v_set(self):
        self.staryy_vhod()
        self.zapusk(n.seychas() - timedelta(hours=1), 3000)
        with self.assertRaises(SystemExit) as e:
            await app.run(self.read())
        self.assertIn("Притормози", str(e.exception))
        self.assertEqual(FakeKlient.sozdano, 0)

    async def test_otkaz_telegram_stavit_stop_i_povtor_ne_vyhodit_v_set(self):
        self.staryy_vhod()
        FakeKlient.otkaz = FloodWaitError(request=None, capture=600)
        with self.assertRaises(SystemExit) as e:
            await app.run(self.read())
        self.assertIn("просил подождать", str(e.exception))
        FakeKlient.otkaz = None
        with self.assertRaises(SystemExit):
            await app.run(self.read())  # сразу повторить нельзя
        with self.assertRaises(SystemExit):
            await app.run(SimpleNamespace(command="status"))
        self.assertEqual(FakeKlient.sozdano, 1)

    async def test_obychnaya_komanda_schitaetsya_i_idet(self):
        self.staryy_vhod()
        await app.run(self.read())
        self.assertTrue((self.root / "o.json").exists())
        sost = json.loads(n.put(self.root).read_text(encoding="utf-8"))
        self.assertEqual(sost.get("stop"), None)
        self.assertEqual([x[1:] for x in sost["seansy"]], [[1, "read"]])  # обращение попало в журнал

    async def test_vhod_rabotal_i_propal_novyy_vhod_srazu_ne_predlagaem(self):
        n.put(self.root).unlink()
        FakeKlient.vhod_est = False
        with self.assertRaises(SystemExit) as e:  # входа ещё не было: обычная подсказка
            await app.run(SimpleNamespace(command="status"))
        self.assertIn("Владелец запускает login", str(e.exception))
        FakeKlient.vhod_est = True
        self.staryy_vhod()
        await app.run(SimpleNamespace(command="status"))
        FakeKlient.vhod_est = False
        with self.assertRaises(SystemExit) as e:
            await app.run(SimpleNamespace(command="status"))
        self.assertIn("Сразу новый вход не делай", str(e.exception))

    async def test_novyy_vhod_nachinaet_razgon_zanovo_a_povtornyy_login_net(self):
        self.staryy_vhod()
        await app.run(SimpleNamespace(command="login"))  # вход уже жив: отметка не меняется
        self.assertGreater(n.svodka(self.root)["chasov"], 24 * 29)
        FakeKlient.vhod_est = False
        await app.run(SimpleNamespace(command="login"))
        sv = n.svodka(self.root)
        self.assertLess(sv["chasov"], 1)
        self.assertEqual((sv["vhod_otkuda"], sv["predel"]), ("login", PROBY))

    async def test_vhod_sostoyalsya_a_zapusk_upal_otmetka_ne_teryaetsya(self):
        self.staryy_vhod()
        FakeKlient.vhod_est, FakeKlient.upast_posle_vhoda = False, True
        with self.assertRaises(RuntimeError):
            await app.run(SimpleNamespace(command="login"))
        sv = n.svodka(self.root)
        self.assertEqual((sv["vhod_otkuda"], sv["predel"]), ("login", PROBY))  # скан в первые сутки закрыт


if __name__ == "__main__":
    unittest.main()
