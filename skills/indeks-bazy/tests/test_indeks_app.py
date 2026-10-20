"""Изолированная проверка индекса: без сети и без настоящей сессии."""
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


class IndexTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = patch.object(app, "DB", Path(self.tmp.name) / "private" / "indeks.sqlite")
        self.p.start()
        self.c = app.db()

    def tearDown(self):
        self.c.close()
        self.p.stop()
        self.tmp.cleanup()

    async def test_sobrat_then_dokachka_only_new(self):
        cl = Client()
        lyudey, novyh = await app.sobrat(cl, self.c, 365, 5, 100)
        self.assertEqual((lyudey, novyh), (1, 8))
        cl.history[201] += [m(9, "Созвонимся завтра?", hours_ago=0)]
        lyudey, novyh = await app.sobrat(cl, self.c, 365, 5, 100)
        self.assertEqual(novyh, 1)
        self.assertEqual(cl.calls[-1], 8)  # второй раз — только новее последнего
        stil, tep = self.c.execute("select stil, teplota from people where id=201").fetchone()
        self.assertIn("на «ты»", stil)
        self.assertEqual(tep, "тёплый")

    def test_stil_reads_voice_and_formal(self):
        t = (NOW - timedelta(days=1)).isoformat()
        rows = [(t, 1, 30, 0, "Добрый день, вам удобно?"), (t, 0, 0, 1, ""), (t, 0, 0, 1, ""), (t, 0, 20, 0, "Да, вам спасибо")]
        s = app.stil(rows)
        self.assertIn("на «вы»", s)
        self.assertIn("голосом", s)

    def test_teplota_levels(self):
        self.assertEqual(app.teplota(NOW.isoformat(), 1, 1, 10), "горячий")
        self.assertEqual(app.teplota((NOW - timedelta(days=90)).isoformat(), 1, 0, 20), "оживить")

    def test_sovpadeniya_and_table_without_names(self):
        self.c.execute("insert into people(id, name, kompaniya, rol, teplota, stil) values(1,'Иван','Банк Север','ИТ-директор','тёплый','на «ты»')")
        self.c.execute("insert into people(id, name, kompaniya, rol, teplota, stil) values(2,'Ольга','Кофейня','владелец','оживить','на «вы»')")
        rows = app.sovpadeniya(self.c, "Ищем ИТ-директоров банков и руководителей закупок", 10)
        self.assertEqual([r[1][1] for r in rows], ["Иван"])
        out = Path(self.tmp.name) / "s.csv"
        txt = app.zapisat(rows, out, False).read_text(encoding="utf-8")
        self.assertNotIn("Иван", txt)
        self.assertIn("Банк Север", txt)


if __name__ == "__main__":
    unittest.main()
