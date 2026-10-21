"""Изолированная проверка отправок. Ни сеть, ни настоящая сессия не используются."""
import asyncio
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from telethon.tl.types import (User, PeerUser, Message, MessageReactions, ReactionCount,
                              ReactionEmoji, MessagePeerReaction, MessageEntityUrl, MessageReplyHeader)
from telethon.tl.functions.messages import GetMessageReactionsListRequest, GetScheduledHistoryRequest

path = Path(__file__).resolve().parents[1] / "scripts" / "telegram_app.py"
spec = importlib.util.spec_from_file_location("telegram_app", path)
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


def msg(mid, text="Текст", out=False, date=None):
    return Message(id=mid, peer_id=PeerUser(200), from_id=PeerUser(100 if out else 200),
                   date=date or datetime.now(timezone.utc), message=text, out=out, entities=[])


class FakeClient:
    def __init__(self):
        self.me = User(id=100, first_name="Владелец")
        self.entity = User(id=200, first_name="Тестовый адресат", username="example_recipient")
        self.latest = msg(7)
        self.messages = {7: self.latest}
        self.scheduled = []
        self.send_calls = []
        self.fail_send = False
        self.corrupt_readback = False
        self.pages = []

    async def get_entity(self, peer): return self.entity
    async def get_input_entity(self, peer): return peer
    async def get_me(self): return self.me

    async def get_messages(self, peer, limit=None, ids=None):
        if ids is not None: return self.messages.get(ids)
        return [self.latest] if self.latest else []

    async def send_message(self, peer, text, **kwargs):
        self.send_calls.append((peer, text, kwargs))
        if self.fail_send: raise TimeoutError("Неизвестный исход")
        result = msg(9, "Другой текст" if self.corrupt_readback else text, out=True,
                     date=kwargs.get("schedule"))
        if kwargs.get("reply_to"):
            result.reply_to = MessageReplyHeader(reply_to_msg_id=kwargs["reply_to"])
        if kwargs.get("schedule"):
            self.scheduled.append(result)
        else:
            self.messages[9] = result
            self.latest = result
        return result

    async def __call__(self, request):
        if isinstance(request, GetScheduledHistoryRequest):
            return SimpleNamespace(messages=self.scheduled)
        if isinstance(request, GetMessageReactionsListRequest):
            return self.pages.pop(0)
        raise AssertionError(type(request))


class SendTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.patcher = patch.object(app, "ROOT", self.root)
        self.patcher.start()
        self.c = FakeClient()

    def tearDown(self):
        self.patcher.stop()
        self.tmp.cleanup()

    async def plan(self, at=None, reply_to=None):
        f = self.root / "message.txt"
        f.write_text("Точный текст 🤝\nhttps://example.com", encoding="utf-8")
        a = SimpleNamespace(chat="200", text_file=str(f), reply_to=reply_to, at=at)
        return await app.prepare_send(self.c, a)

    def authorization(self, plan):
        return {**{k: plan[k] for k in ("account_id", "chat_id", "text_sha256", "reply_to", "schedule")},
                "source": "Прямое тестовое поручение 1", "owner_text": "Отправь названному адресату этот текст"}

    async def test_send_exact_plaintext_and_read_back(self):
        p = await self.plan()
        r = await app.send_plan(self.c, p, self.authorization(p))
        self.assertEqual(r["status"], "sent_verified")
        self.assertEqual(r["read_back"]["text"], p["text"])
        self.assertIsNone(self.c.send_calls[0][2]["parse_mode"])
        self.assertEqual(json.loads(app.operation_path(p["id"]).read_text())["message_id"], 9)

    async def test_repeat_verifies_without_second_send(self):
        p = await self.plan(); a = self.authorization(p)
        await app.send_plan(self.c, p, a)
        await app.send_plan(self.c, p, a)
        self.assertEqual(len(self.c.send_calls), 1)

    async def test_missing_or_mismatched_authorization_never_sends(self):
        p = await self.plan()
        for field in ("account_id", "chat_id", "text_sha256", "reply_to", "schedule", "owner_text", "source"):
            a = self.authorization(p); del a[field]
            with self.assertRaises(SystemExit): await app.send_plan(self.c, p, a)
        a = self.authorization(p); a["chat_id"] = 999
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, a)
        self.assertEqual(self.c.send_calls, [])

    async def test_changed_text_does_not_reuse_authorization(self):
        p = await self.plan(); a = self.authorization(p)
        p["text"] = "Изменённый текст"; p["text_sha256"] = app.digest(p["text"])
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, a)
        self.assertEqual(self.c.send_calls, [])

    async def test_new_incoming_message_stops_stale_plan(self):
        p = await self.plan(); self.c.latest = msg(8, "Поздний ответ")
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, self.authorization(p))
        self.assertEqual(self.c.send_calls, [])

    async def test_edited_message_in_context_stops_stale_plan(self):
        p = await self.plan()
        self.c.latest = Message(id=7, peer_id=PeerUser(200), from_id=PeerUser(200), date=datetime.now(timezone.utc),
                                message="Текст исправлен", out=False, entities=[], edit_date=datetime.now(timezone.utc))
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, self.authorization(p))
        self.assertEqual(self.c.send_calls, [])

    async def test_human_correction_is_found_once_for_lesson(self):
        p = await self.plan()
        await app.send_plan(self.c, p, self.authorization(p))
        self.assertEqual(await app.ispravleniya(self.c), [])
        self.c.messages[9] = Message(id=9, peer_id=PeerUser(200), from_id=PeerUser(100), date=datetime.now(timezone.utc),
                                     message="Человек поправил", out=True, entities=[], edit_date=datetime.now(timezone.utc))
        rows = await app.ispravleniya(self.c)
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["bylo"], rows[0]["stalo"]), (p["text"], "Человек поправил"))
        self.assertEqual(await app.ispravleniya(self.c), [])

    async def test_account_mismatch_stops_send(self):
        p = await self.plan(); self.c.me.id = 999
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, self.authorization(p))
        self.assertEqual(self.c.send_calls, [])

    async def test_network_unknown_outcome_is_not_retried(self):
        p = await self.plan(); a = self.authorization(p); self.c.fail_send = True
        with self.assertRaises(TimeoutError): await app.send_plan(self.c, p, a)
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, a)
        self.assertEqual(len(self.c.send_calls), 1)
        self.assertEqual(json.loads(app.operation_path(p["id"]).read_text())["status"], "outcome_unknown")

    async def test_bad_readback_never_sends_again(self):
        p = await self.plan(); a = self.authorization(p); self.c.corrupt_readback = True
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, a)
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, a)
        self.assertEqual(len(self.c.send_calls), 1)

    async def test_reply_to_is_sent_and_read_back(self):
        p = await self.plan(reply_to=7)
        r = await app.send_plan(self.c, p, self.authorization(p))
        self.assertEqual(r["read_back"]["reply_to_msg_id"], 7)

    async def test_deleted_reply_target_blocks_send(self):
        p = await self.plan(reply_to=7)
        del self.c.messages[7]
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, self.authorization(p))
        self.assertEqual(self.c.send_calls, [])

    async def test_scheduled_reminder_verified_in_queue(self):
        at = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
        p = await self.plan(at)
        r = await app.send_plan(self.c, p, self.authorization(p), remind=True)
        self.assertEqual(r["status"], "scheduled_verified")
        self.assertEqual(self.c.send_calls[0][2]["schedule"], app.scheduled_time(at))

    async def test_remind_requires_time_and_expired_time_stops(self):
        p = await self.plan()
        with self.assertRaises(SystemExit): await app.send_plan(self.c, p, self.authorization(p), remind=True)
        with self.assertRaises(SystemExit): await self.plan("2020-01-01T12:00:00+03:00")
        with self.assertRaises(SystemExit): app.scheduled_time("2026-11-01T12:00:00")
        self.assertEqual(self.c.send_calls, [])

    async def test_unavailable_reaction_people_not_reported_as_no_reaction(self):
        m = self.c.messages[7]
        m.reactions = MessageReactions(results=[ReactionCount(ReactionEmoji("🤝"), 2)], can_see_list=False)
        r = await app.reactions(self.c, "200", 7, 100)
        self.assertEqual(r["message"]["reactions"], [{"emoji": "🤝", "count": 2}])
        self.assertFalse(r["people_complete"])
        self.assertEqual(r["message"]["sender_id"], 200)

    async def test_reactions_are_bound_to_message_and_paginated(self):
        self.c.messages[7].reactions = MessageReactions(
            results=[ReactionCount(ReactionEmoji("🤝"), 2)], can_see_list=True)
        def page(pid, offset):
            return SimpleNamespace(count=2, users=[User(id=pid, first_name="Тест")],
                reactions=[MessagePeerReaction(PeerUser(pid), datetime.now(timezone.utc), ReactionEmoji("🤝"))],
                next_offset=offset)
        self.c.pages = [page(300, "next"), page(301, None)]
        r = await app.reactions(self.c, "200", 7, 100)
        self.assertTrue(r["people_complete"])
        self.assertEqual([x["peer_id"] for x in r["people"]], [300, 301])
        self.assertEqual(r["message"]["id"], 7)

    async def test_reaction_limit_marks_partial_result(self):
        self.c.messages[7].reactions = MessageReactions(
            results=[ReactionCount(ReactionEmoji("🤝"), 2)], can_see_list=True)
        self.c.pages = [SimpleNamespace(count=2, users=[], reactions=[MessagePeerReaction(
            PeerUser(300), datetime.now(timezone.utc), ReactionEmoji("🤝"))], next_offset="next")]
        r = await app.reactions(self.c, "200", 7, 1)
        self.assertTrue(r["people_available"])
        self.assertFalse(r["people_complete"])

    async def test_session_lock_excludes_another_process(self):
        with app.session_lock():
            with self.assertRaises(SystemExit):
                with app.session_lock(): pass
        self.assertFalse((self.root / ".telegram.lock").exists())

    async def test_missing_optional_reaction_date_is_supported(self):
        self.c.messages[7].reactions = MessageReactions(
            results=[ReactionCount(ReactionEmoji("🤝"), 1)], can_see_list=True)
        self.c.pages = [SimpleNamespace(count=1, users=[], reactions=[MessagePeerReaction(
            PeerUser(300), None, ReactionEmoji("🤝"))], next_offset=None)]
        r = await app.reactions(self.c, "200", 7, 100)
        self.assertIsNone(r["people"][0]["date"])
        self.assertTrue(r["people_complete"])

    async def test_utf16_link_after_emoji_preserved(self):
        m = msg(7, "🙂 https://example.com")
        m.entities = [MessageEntityUrl(offset=3, length=19)]
        self.assertEqual(app.ssylki(m), ["https://example.com"])


if __name__ == "__main__": unittest.main()


class FakeDialog:
    def __init__(self, did, name, last, is_user=True, bot=False, unread=0, mark=False, pinned=False):
        self.id, self.name, self.message, self.is_user = did, name, last, is_user
        self.entity = User(id=did, first_name=name, bot=bot)
        self.unread_count, self.pinned = unread, pinned
        self.dialog = SimpleNamespace(unread_mark=mark)


class MemoryClient(FakeClient):
    def __init__(self):
        super().__init__()
        self.history = [msg(i, f"Сообщение {i}") for i in range(1, 11)]
        self.calls = []
        now = datetime.now(timezone.utc)
        self.dialogs = [
            FakeDialog(201, "Ждёт ответа", msg(1, "Когда созвонимся?", date=now)),
            FakeDialog(202, "Ответили мы", msg(2, "Договорились", out=True, date=now)),
            FakeDialog(203, "Пометка", msg(3, "ок", out=True, date=now), mark=True),
            FakeDialog(204, "Бот", msg(4, "Меню", date=now), bot=True),
            FakeDialog(205, "Группа", msg(5, "Всем привет", date=now), is_user=False),
            FakeDialog(206, "Старый", msg(6, "Давно", date=now - timedelta(days=40))),
            FakeDialog(207, "За окном", msg(7, "Ещё старее", date=now - timedelta(days=50))),
        ]

    async def iter_dialogs(self, limit=None):
        for d in self.dialogs[:limit]:
            yield d

    async def get_messages(self, peer, limit=None, ids=None, min_id=0, reverse=False):
        self.calls.append((limit, min_id, reverse))
        rows = [m for m in self.history if m.id > min_id]
        rows = rows if reverse else list(reversed(rows))
        return rows[:limit]


class MemoryTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.patcher = patch.object(app, "ROOT", Path(self.tmp.name))
        self.patcher.start()
        self.c = MemoryClient()

    def tearDown(self):
        self.patcher.stop()
        self.tmp.cleanup()

    async def test_unanswered_keeps_people_waiting_and_marked(self):
        rows = await app.unanswered(self.c, 14, 200)
        self.assertEqual([r["name"] for r in rows], ["Ждёт ответа", "Пометка"])

    async def test_read_novoe_continues_without_gap(self):
        first = await app.read(self.c, "200", 4)
        self.assertEqual([r["id"] for r in first], [10, 9, 8, 7])
        self.c.history += [msg(i, f"Новое {i}") for i in range(11, 17)]
        part1 = await app.read(self.c, "200", 4, novoe=True, liniya="Пара А–Б")
        part2 = await app.read(self.c, "200", 4, novoe=True)
        self.assertEqual([r["id"] for r in part1 + part2], [11, 12, 13, 14, 15, 16])
        mem = json.loads(app.pamyat_path().read_text(encoding="utf-8"))
        zap = next(iter(mem.values()))
        self.assertEqual((zap["read_id"], zap["liniya"]), (16, "Пара А–Б"))
        self.assertEqual(await app.read(self.c, "200", 4, novoe=True), [])
