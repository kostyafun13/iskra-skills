"""Изолированная проверка скила «Круги». Ни сети, ни аккаунтов Telegram и Google: только чистая логика."""
import asyncio
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def zagruzit(imya):
    spec = importlib.util.spec_from_file_location(imya, SCRIPTS / f"{imya}.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


deka, plan, tg, partner = (zagruzit(x) for x in ("krug_deka", "krugi_plan", "krugi_tg", "krugi_partner"))


def chelovek(k, imya, **dop):
    p = {"k": k, "imya": imya, "komp": "Компания · суть", "sub": "строка", "svyaz": "**Б** полезен",
         **{f"o{i}": f"блок {i}" for i in range(1, 6)}}
    p.update(dop)
    return p


def papka_partii(t, krugi, teksty, fayl="krugi.json"):
    d = Path(t) / "dannye"
    d.mkdir(parents=True, exist_ok=True)
    (d / fayl).write_text(json.dumps(krugi, ensure_ascii=False), encoding="utf-8")
    for n, tekst in teksty.items():
        (d / f"krug_{n}.json").write_text(json.dumps(tekst, ensure_ascii=False), encoding="utf-8")
    return Path(t)


class Deka(unittest.TestCase):
    def setUp(self):
        self.n = deka.nastroyki(Path("/net/takogo/fayla.json"))
        self.n.update(kicker="Круг", moderator="Модератор")

    def html(self, lyudi, tema="Банки и малый бизнес"):
        with tempfile.TemporaryDirectory() as t:
            return deka.html_kruga({"n": 7, "tema": tema}, {"n": 7, "mysl": "**Общий покупатель.** Банки.", "lyudi": lyudi}, self.n, t)

    def test_bez_nomera_kruga(self):
        h = self.html([chelovek("a", "Анна Б")])
        self.assertNotIn("Круг 7", h)
        self.assertNotIn(">7<", h)

    def test_tochka_tolko_u_nepodtverzhdennyh(self):
        h = self.html([chelovek("a", "А Б", vyruchka_ok=False), chelovek("b", "В Г", vyruchka_ok=True), chelovek("c", "Д Е", vyruchka_ok=None)])
        self.assertEqual(h.count('class="tochka bigt"'), 1)
        self.assertEqual(h.count('class="tochka portt"'), 1)
        self.assertNotIn("выручка не подтверждена", h)

    def test_dva_ryada_bolshe_pyati(self):
        self.assertIn('class="grid dva"', self.html([chelovek(str(i), f"Имя {i}") for i in range(6)]))
        self.assertNotIn('class="grid dva"', self.html([chelovek(str(i), f"Имя {i}") for i in range(5)]))

    def test_initsialy_i_ekranirovanie(self):
        h = self.html([chelovek("a", "Иван Петров", o1="<script>x</script> **жирно**")])
        self.assertIn(">ИП<", h)
        self.assertNotIn("<script>x", h)
        self.assertIn("<b>жирно</b>", h)

    def test_chelovek_na_oblozhke_odin_raz(self):
        h = self.html([chelovek("a", "Иван Петров")])
        oblozhka = h.split("</section>")[0]
        self.assertEqual(oblozhka.count("Иван Петров"), 1)

    def test_imya_pdf(self):
        f = deka.imya_pdf("/x", {"n": 3, "tema": "Стройка: подрядчики/контроль"}, self.n)
        self.assertEqual(f.name, "Круг — Стройка  подрядчики контроль.pdf")


class Plan(unittest.TestCase):
    def test_stroki(self):
        p = {"k": "a", "imya": "Анна"}
        self.assertEqual(plan.stroka(p, "Иван", "anna_nik", "Иван"), "— Анна · пишет Иван")  # ник владельца не светим
        self.assertEqual(plan.stroka(p, "партнёр", "anna_nik", "Иван"), "— Анна @anna_nik")
        self.assertEqual(plan.stroka(p, "партнёр", "", "Иван"), "— Анна · ника нет")
        self.assertEqual(plan.stroka(dict(p, vyruchka_ok=False), "партнёр", "", "Иван"), "— Анна · ника нет (?)")
        self.assertEqual(plan.stroka(dict(p, vyruchka_ok=True), "партнёр", "x_nik", "", True), "— Анна @x_nik · якорь 30+")

    def test_kto_zovet_ne_ukazano(self):
        p = {"k": "a", "imya": "Анна"}
        self.assertEqual(plan.stroka(p, "", "anna_nik", "Иван"), "— Анна · кто зовёт — не указано")  # ник не светим
        self.assertEqual(plan.stroka(p, "Маша", "anna_nik", "Иван", partner="Пётр"), "— Анна · кто зовёт — не указано")
        self.assertEqual(plan.stroka(p, "Пётр (из чатов)", "anna_nik", "Иван", partner="Пётр"), "— Анна @anna_nik")

    def test_razrezat_dlinnyy_zagolovok_i_emodzi(self):
        golova = "Круги — 300, быстрый просмотр очень длинного заголовка партии кругов на весь ноябрь\n\nлегенда"
        bloki = [f"{i}. Тема 🚀🚀\nОхота: кто-то\n" + "\n".join(f"— Человек {j} 🙂 @nik_{j}" for j in range(9)) for i in range(120)]
        for c in plan.razrezat(golova, bloki):
            self.assertLessEqual(plan.dlina(c), plan.PREDEL)

    def test_chistyy_nik(self):
        self.assertEqual(plan.chistyy_nik("@ivan_p (по телефону)"), "ivan_p")
        self.assertEqual(plan.chistyy_nik("https://t.me/ivan_p"), "ivan_p")
        self.assertEqual(plan.chistyy_nik("нет ника"), "")
        self.assertEqual(plan.chistyy_nik(""), "")

    def test_razrezat(self):
        bloki = [f"{i}. Тема\nОхота: кто-то\n" + "\n".join(f"— Человек {j} @nik_{j}" for j in range(8)) for i in range(60)]
        chasti = plan.razrezat("Круги — 60, быстрый просмотр\n\nлегенда", bloki)
        self.assertGreater(len(chasti), 1)
        for c in chasti:
            self.assertLessEqual(len(c), plan.PREDEL)
            self.assertEqual(c, c.rstrip())
        vse = "\n\n".join(chasti)
        for b in bloki:
            self.assertIn(b, vse)  # круг не рвётся между сообщениями
        self.assertIn("(1/", chasti[0].split("\n")[0])

    def test_niki_poryadok(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t) / "dannye"
            d.mkdir()
            (d / "niki_po_telefonu.json").write_text(json.dumps({"a": {"tg": True, "nik": "po_tel"}, "b": {"tg": True, "nik": "po_tel_b"}}))
            (d / "niki_ot_partnera.json").write_text(json.dumps({"a": "@ot_partnera (позвал)"}))
            (d / "niki.json").write_text(json.dumps({"b": "vruchnuyu", "a": "нет ника"}))
            self.assertEqual(plan.niki(t), {"a": "ot_partnera", "b": "vruchnuyu"})  # мусор не стирает верный ник

    def test_sobrat_plan(self):
        with tempfile.TemporaryDirectory() as t:
            papka_partii(t, [{"n": 1, "tema": "Банки", "ohota": "Банк А", "lyudi": [{"k": "a", "zovet": "Иван"}, {"k": "b", "zovet": "Партнёр"}]}],
                         {1: {"n": 1, "mysl": "м", "lyudi": [chelovek("a", "Анна"), chelovek("b", "Борис", nik="boris_x", vyruchka_ok=False)]}})
            chasti = plan.sobrat_plan(t, nastr={"vladelec": "Иван", "partner": {"imya": "Партнёр"}})
        self.assertEqual(len(chasti), 1)
        self.assertIn("— Анна · пишет Иван", chasti[0])
        self.assertIn("— Борис @boris_x (?)", chasti[0])
        self.assertIn("Охота: Банк А", chasti[0])


class Telegram(unittest.TestCase):
    def test_telefon(self):
        self.assertEqual(tg.telefon("8 (000) 000-00-01"), "+70000000001")
        self.assertEqual(tg.telefon("0000000001"), "+70000000001")
        self.assertEqual(tg.telefon("+44 000 000 0002"), "+440000000002")
        self.assertIsNone(tg.telefon("123"))
        self.assertIsNone(tg.telefon(None))

    def test_zadachi_po_telefonu(self):
        vhod = [{"k": "a", "imya": "А", "telefon": "80000000001"}, {"k": "b", "telefon": "80000000002", "nik": "uzhe"},
                {"k": "c", "telefon": "80000000003"}, {"k": "d", "telefon": ""}]
        z = tg.zadachi_po_telefonu(vhod, {"c": {"tg": False}})
        self.assertEqual([x[0] for x in z], ["a"])

    def test_proverit_kadry(self):
        with tempfile.TemporaryDirectory() as t:
            f = Path(t) / "d.pdf"
            f.write_bytes(b"%PDF")
            kk = [("plan_1", "текст", None), ("plan_2", "текст\n", None), ("deka_1", "п" * 1025, f), ("deka_2", "ок", Path(t) / "net.pdf")]
            oshibki = tg.proverit_kadry(kk)
        self.assertEqual(len(oshibki), 3)
        self.assertFalse(any("plan_1" in o for o in oshibki))

    def test_oshibka_odnogo(self):
        class RPCError(Exception):
            pass

        class UsernameNotOccupiedError(RPCError):
            pass

        class FloodWaitError(RPCError):
            seconds = 30

        class Pritormozi(Exception):
            pass

        class N:
            @staticmethod
            def vid_otkaza(e):
                return "zhdat" if isinstance(e, FloodWaitError) else None

        self.assertTrue(tg.oshibka_odnogo(ValueError("нет ника"), N))
        self.assertTrue(tg.oshibka_odnogo(UsernameNotOccupiedError(), N))
        self.assertFalse(tg.oshibka_odnogo(FloodWaitError(), N))
        self.assertFalse(tg.oshibka_odnogo(Pritormozi(), N))  # «притормози» сторожа не глотаем
        self.assertFalse(tg.oshibka_odnogo(ConnectionError(), N))

    def test_ostatok_poiska(self):
        now = 1_000_000.0
        self.assertEqual(tg.ostatok_poiska({}, now), (tg.POISK_ZA_SUTKI, 0))
        sost = {"zapuski": [[now - 90000, 40], [now - 3600, 30]], "stop_do": now + 60}
        self.assertEqual(tg.ostatok_poiska(sost, now), (tg.POISK_ZA_SUTKI - 30, now + 60))  # старше суток не считается

    def test_oshibka_ozhidaniya_stop(self):
        class RPCError(Exception):
            pass

        class SlowModeWaitError(RPCError):
            pass

        class N:
            @staticmethod
            def vid_otkaza(e):
                return None

        self.assertFalse(tg.oshibka_odnogo(SlowModeWaitError(), N))

    def test_prevyu_ne_v_tmp(self):
        with tempfile.TemporaryDirectory() as t:
            pdf = Path(t) / "pdf" / "d.pdf"
            pdf.parent.mkdir()
            pdf.write_bytes(b"%PDF")
            try:
                tg.prevyu(pdf)
            except (SystemExit, Exception):
                pass  # sips на пустышке падает — важно, куда целится
            self.assertTrue((Path(t) / "prevyu").is_dir())

    def test_bez_storozha_ne_rabotaet(self):
        async def popytka(papka):
            async with tg.seans(Path(papka), "chtenie", "test"):
                pass
        with tempfile.TemporaryDirectory() as t:
            with self.assertRaises(SystemExit) as e:
                asyncio.run(popytka(t))
            self.assertIn("сторожа", str(e.exception))

    def test_zanyataya_sessiya(self):
        async def popytka(papka):
            async with tg.seans(Path(papka), "chtenie", "test"):
                pass
        with tempfile.TemporaryDirectory() as t:
            (Path(t) / "nagruzka.py").write_text("def proverit(root, vid):\n    return {}\n")
            (Path(t) / ".telegram.lock").write_text("123")
            with self.assertRaises(SystemExit) as e:
                asyncio.run(popytka(t))
            self.assertIn("занята", str(e.exception))
            self.assertTrue((Path(t) / ".telegram.lock").exists())  # чужой замок не снимаем

    def test_kadry_po_poryadku(self):
        with tempfile.TemporaryDirectory() as t:
            p = papka_partii(t, [{"n": 2, "tema": "Ритейл"}, {"n": 1, "tema": "Банки"}],
                             {1: {"n": 1, "mysl": "м", "lyudi": []}, 2: {"n": 2, "mysl": "м", "lyudi": []}})
            (p / "dannye" / "plan.json").write_text(json.dumps(["часть 1", "часть 2"]))
            kk = tg.kadry(p, {"priglashenie": "Приглашаю на круг"})
            self.assertEqual([x[0] for x in kk], ["plan_1", "plan_2", "deka_2", "deka_1"])
            self.assertTrue(all(x[1] == "Приглашаю на круг" for x in kk[2:]))
            with self.assertRaises(SystemExit):
                tg.kadry(p, {"priglashenie": ""})


class Partner(unittest.TestCase):
    def test_sliyanie(self):
        staroe = [["Банки", "Анна", "К", "партнёр", "@anna", "позвал", "12.11", "", "a"],
                  ["Ритейл", "Ушёл", "К", "партнёр", "@ushel", "отказался", "", "", "z"],
                  ["Ритейл", "Пусто", "К", "партнёр", "", "", "", "", "y"],
                  ["", "Новый", "Комп", "", "@novyy", "новый — добавил партнёр", "", "", ""]]
        nashi = [["Банки", "Борис", "К", "партнёр", "b"], ["Банки (новая тема)", "Анна", "К2", "партнёр", "a"]]
        vse = partner.sliyanie(staroe, nashi, {"a": "@drugoy (по телефону)", "b": "@boris (по телефону)"})
        self.assertEqual([r[1] for r in vse], ["Анна", "Ушёл", "Новый", "Борис"])  # старые на местах, новые внизу
        self.assertEqual(vse[0], ["Банки (новая тема)", "Анна", "К2", "партнёр", "@anna", "позвал", "12.11", "", "a"])
        self.assertEqual(vse[1][3], "вне кругов сейчас")
        self.assertEqual(vse[1][4:8], ["@ushel", "отказался", "", ""])
        self.assertEqual(vse[3][4], "@boris (по телефону)")  # пустую ячейку подсказка заполняет

    def test_zapis_bez_pustogo_lista(self):
        vyzovy = []

        class Zapros:
            def __init__(self, imya, kw):
                self.imya, self.kw = imya, kw

            def execute(self):
                vyzovy.append((self.imya, self.kw.get("range")))
                return {}

        class Values:
            def update(self, **kw):
                return Zapros("update", kw)

            def clear(self, **kw):
                return Zapros("clear", kw)

        class Sh:
            def spreadsheets(self):
                return self

            def values(self):
                return Values()

        partner.zapisat_list(Sh(), "id", "Лист", [["a"], ["b"]], bylo_strok=5)
        self.assertEqual(vyzovy, [("update", "'Лист'!A1"), ("clear", "'Лист'!A3:Z5")])  # сначала запись, потом хвост

    def test_bezopasno(self):
        self.assertEqual(partner.bezopasno("=HYPERLINK(1)"), "'=HYPERLINK(1)")
        self.assertEqual(partner.bezopasno("Анна"), "Анна")

    def test_lyudi_vladelca_ne_idut_partneru(self):
        with tempfile.TemporaryDirectory() as t:
            papka_partii(t, [{"n": 1, "tema": "Банки", "lyudi": [{"k": "a", "zovet": "Иван"}, {"k": "b", "zovet": "Партнёр"},
                                                                  {"k": "c", "zovet": ""}]},
                             {"n": 2, "tema": "Ритейл", "lyudi": [{"k": "b", "zovet": "Партнёр"}]}],
                         {1: {"n": 1, "mysl": "м", "lyudi": [chelovek("a", "Анна"), chelovek("b", "Борис"), chelovek("c", "Вера")]},
                          2: {"n": 2, "mysl": "м", "lyudi": [chelovek("b", "Борис")]}})
            out = partner.lyudi_partnera(t, "Иван")
        self.assertEqual([r[4] for r in out], ["b"])  # «не указано» партнёру не отдаём; два круга — одна строка


if __name__ == "__main__":
    unittest.main()
