"""Изолированная проверка: подменённые сервисы Google, ни сети, ни аккаунта, никому ничего не уходит."""
import base64
from email import message_from_bytes
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location("google_app", Path(__file__).resolve().parent.parent / "scripts" / "google_app.py")
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)

EVENT = {"id": "e1", "summary": "Встреча", "start": {"dateTime": "2026-11-06T12:00:00+03:00"}, "end": {"dateTime": "2026-11-06T13:00:00+03:00"}}


class Time(unittest.TestCase):
    def test_timezone_required(self):
        self.assertEqual(app.moment("2026-11-06T12:00:00+03:00"), {"dateTime": "2026-11-06T12:00:00+03:00"})
        with self.assertRaises(SystemExit):
            app.moment("2026-11-06T12:00:00")
        with self.assertRaises(SystemExit):
            app.moment("завтра")


class Calendar(unittest.TestCase):
    def setUp(self):
        self.c = MagicMock()
        self.c.insert.return_value.execute.return_value = EVENT
        self.c.patch.return_value.execute.return_value = EVENT

    def args(self, *argv):
        return app.cli(list(argv))

    def test_no_attendee_notifies_nobody(self):
        app.create_event(self.c, self.args("create-event", "--title", "T", "--start", "2026-11-06T12:00:00+03:00", "--end", "2026-11-06T13:00:00+03:00"))
        kw = self.c.insert.call_args.kwargs
        self.assertEqual(kw["sendUpdates"], "none")
        self.assertNotIn("attendees", kw["body"])

    def test_attendee_gets_invite(self):
        app.create_event(self.c, self.args("create-event", "--title", "T", "--start", "2026-11-06T12:00:00+03:00", "--end", "2026-11-06T13:00:00+03:00", "--attendee", "a@example.com"))
        kw = self.c.insert.call_args.kwargs
        self.assertEqual(kw["sendUpdates"], "all")
        self.assertEqual(kw["body"]["attendees"], [{"email": "a@example.com"}])

    def test_update_only_given_fields_and_silent_by_default(self):
        app.update_event(self.c, self.args("update-event", "--id", "e1", "--title", "Новая"))
        kw = self.c.patch.call_args.kwargs
        self.assertEqual(kw["body"], {"summary": "Новая"})
        self.assertEqual(kw["sendUpdates"], "none")

    def test_update_without_fields_refused(self):
        with self.assertRaises(SystemExit):
            app.update_event(self.c, self.args("update-event", "--id", "e1"))

    def test_delete_silent_unless_notify(self):
        app.delete_event(self.c, self.args("delete-event", "--id", "e1"))
        self.assertEqual(self.c.delete.call_args.kwargs["sendUpdates"], "none")
        app.delete_event(self.c, self.args("delete-event", "--id", "e1", "--notify"))
        self.assertEqual(self.c.delete.call_args.kwargs["sendUpdates"], "all")


class Mail(unittest.TestCase):
    def test_draft_is_not_sent(self):
        mail = MagicMock()
        mail.drafts.return_value.create.return_value.execute.return_value = {"id": "d1"}
        app.mail_draft(mail, "a@example.com", "Тема", "Текст письма")
        raw = mail.drafts.return_value.create.call_args.kwargs["body"]["message"]["raw"]
        m = message_from_bytes(base64.urlsafe_b64decode(raw))
        self.assertEqual(m["To"], "a@example.com")
        mail.messages.return_value.send.assert_not_called()
        mail.drafts.return_value.send.assert_not_called()

    def test_read_text_and_attachment_names(self):
        mail = MagicMock()
        data = base64.urlsafe_b64encode("Привет".encode()).decode()
        mail.messages.return_value.get.return_value.execute.return_value = {"payload": {
            "headers": [{"name": "Subject", "value": "Т"}],
            "parts": [{"mimeType": "text/plain", "body": {"data": data}}, {"filename": "a.pdf", "mimeType": "application/pdf", "body": {}}]}}
        row = app.mail_read(mail, "m1")
        self.assertEqual(row["text"], "Привет")
        self.assertEqual(row["attachments"], ["a.pdf"])


class Secrets(unittest.TestCase):
    def test_private_file_only_for_owner(self):
        with tempfile.TemporaryDirectory() as t:
            path = app.write_private(Path(t) / "token.json", "{}")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_old_token_asks_for_login(self):
        self.assertTrue(app.missing_scopes(["https://www.googleapis.com/auth/drive.file"]))
        self.assertEqual(app.missing_scopes(app.SCOPES), [])
        with tempfile.TemporaryDirectory() as t:
            (Path(t) / "token.json").write_text(json.dumps({"scopes": ["https://www.googleapis.com/auth/drive.file"]}), encoding="utf-8")
            with patch.object(app, "ROOT", Path(t)), self.assertRaises(SystemExit):
                app.credentials()


class Links(unittest.TestCase):
    def test_file_id_from_link(self):
        self.assertEqual(app.file_id("https://drive.google.com/drive/folders/abcdefghijklmnopqrstuvwx?x=1"), "abcdefghijklmnopqrstuvwx")
        self.assertEqual(app.file_id("abc"), "abc")


if __name__ == "__main__":
    unittest.main()
