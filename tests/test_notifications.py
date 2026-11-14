import concurrent.futures
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / "scripts/calendar-notify"
APP_ID = "re_pick.google-calendar-clock"
SERVICE = "org.freedesktop.Notifications"
OBJECT = "/org/freedesktop/Notifications"
TIMEOUT_HEADLINE = "fixture-timeout"
ERROR_HEADLINE = "fixture-error"


def serve_notifications():
    from gi.repository import Gio, GLib

    xml = f"""<node><interface name='{SERVICE}'><method name='Notify'>
        <arg type='s' direction='in'/><arg type='u' direction='in'/>
        <arg type='s' direction='in'/><arg type='s' direction='in'/>
        <arg type='s' direction='in'/><arg type='as' direction='in'/>
        <arg type='a{{sv}}' direction='in'/><arg type='i' direction='in'/>
        <arg type='u' direction='out'/>
    </method></interface></node>"""
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def daemon_call(method, arguments):
        return bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                             method, arguments, None, Gio.DBusCallFlags.NONE, 2000, None).unpack()[0]

    def notify(_connection, sender, _object, _interface, _method, parameters, invitation):
        data = parameters.unpack()
        pid = daemon_call("GetConnectionUnixProcessID", GLib.Variant("(s)", (sender,)))
        process = Path("/proc") / str(pid)
        children = (process / "task" / str(pid) / "children").read_text().split()
        argv = (process / "cmdline").read_bytes().rstrip(b"\0").decode().split("\0")
        environment = (process / "environ").read_bytes().rstrip(b"\0").decode().split("\0")
        print(json.dumps({"data": data, "argv": argv, "environ": environment, "children": children}), flush=True)
        if data[3] == TIMEOUT_HEADLINE:
            GLib.timeout_add_seconds(4, lambda: invitation.return_value(GLib.Variant("(u)", (1,))) or False)
        elif data[3] == ERROR_HEADLINE:
            invitation.return_dbus_error("org.freedesktop.DBus.Error.NameHasNoOwner", data[4])
        else:
            invitation.return_value(GLib.Variant("(u)", (1,)))

    interface = Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
    bus.register_object(OBJECT, interface, notify, None, None)
    assert daemon_call("RequestName", GLib.Variant("(su)", (SERVICE, 0))) == 1
    loop = GLib.MainLoop()

    def stop(_fd, _condition):
        loop.quit()
        return False

    GLib.io_add_watch(sys.stdin.fileno(), GLib.PRIORITY_DEFAULT, GLib.IO_HUP, stop)
    print(json.dumps({"bus": os.environ["DBUS_SESSION_BUS_ADDRESS"]}), flush=True)
    loop.run()


class NotificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("dbus-run-session") or importlib.util.find_spec("gi") is None:
            raise unittest.SkipTest("Notification tests require dbus-run-session and python-gobject")
        fixture = subprocess.Popen(["dbus-run-session", "--", sys.executable, "-B", __file__, "serve"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

        def stop():
            fixture.stdin.close()
            try:
                fixture.wait(timeout=3)
            finally:
                if fixture.poll() is None:
                    fixture.kill()
                    fixture.wait()
                fixture.stdout.close()

        cls.addClassCleanup(stop)
        cls.messages = queue.Queue()

        def read_messages():
            for line in fixture.stdout:
                cls.messages.put(json.loads(line))

        threading.Thread(target=read_messages, daemon=True).start()
        cls.bus = cls.messages.get(timeout=5)["bus"]

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.state_dir = self.root / "omarchy-calendar"
        self.state = self.state_dir / "reminders.json"
        self.env = {
            "PATH": "/usr/bin:/bin", "XDG_STATE_HOME": str(self.root),
            "DBUS_SESSION_BUS_ADDRESS": self.bus, "PYTHONDONTWRITEBYTECODE": "1",
        }

    def call(self, body, *, arguments=(), env=None, command=None):
        payload = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        return subprocess.run(command or [str(HELPER), *arguments], input=payload, capture_output=True,
                              env=env if env is not None else self.env, timeout=10)

    @staticmethod
    def reminder(key="private-event@calendar.test|7", **changes):
        return {"key": key, "headline": "Секретный заголовок", "body": "Через 7 минут\n14 нояб., 19:41",
                "link": "https://meet.google.com/fixture-room?token=private-meeting&code=abcd", **changes}

    def capture(self):
        return self.messages.get(timeout=5)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((result.stdout, result.stderr), (b"", b""))

    def test_private_wire_message_and_click_command(self):
        reminder = self.reminder(headline='--exec "Календарь"\n<img src="https://tracker.invalid/hidden">',
                                 body="Через 7 минут\n14 нояб., 19:41\n<b>Обычный текст</b> &amp;\0")
        self.assert_success(self.call(reminder, env={**self.env, "G_DBUS_DEBUG": "message"}))
        capture = self.capture()
        self.assertEqual(capture["argv"], ["/usr/bin/python3", str(HELPER)])
        self.assertEqual(capture["children"], [])
        process_data = "\0".join(capture["argv"] + capture["environ"])
        for value in (reminder["key"], "Календарь", "19:41", "private-meeting", "tracker.invalid"):
            self.assertNotIn(value, process_data)
        self.assertEqual(capture["data"], [
            APP_ID, 0, "", '--exec "Календарь"\n＜img src="https://tracker.invalid/hidden"＞',
            "Через 7 минут\n14 нояб., 19:41\n＜b＞Обычный текст＜/b＞ ＆amp;\n" + reminder["link"],
            [], {"urgency": 1, "omarchy-glyph": "󰃭", "omarchy-exec-argv":
                 json.dumps(["omarchy-shell", "shell", "summon", APP_ID, "{}"], separators=(",", ":"))}, -1,
        ])

    def test_parallel_screens_and_restart_deduplicate_only_matching_reminders(self):
        first = self.reminder(headline="First parallel reminder")
        second = self.reminder(key="second-event|0", headline="Second parallel reminder")
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            futures = [pool.submit(self.call, reminder) for reminder in [first, second] * 3]
            for future in futures:
                self.assert_success(future.result())
        self.assertEqual({self.capture()["data"][3] for _ in range(2)}, {first["headline"], second["headline"]})
        self.assert_success(self.call(first))
        self.assertTrue(self.messages.empty())
        self.assertEqual(len(json.loads(self.state.read_bytes())), 2)

    def test_migration_keeps_recent_entries_in_private_files(self):
        self.state_dir.mkdir(mode=0o755)
        self.state.write_text("{}")
        self.state.chmod(0o644)
        lock = self.state_dir / "reminders.lock"
        lock.touch(mode=0o644)
        recent = self.reminder()
        expired = self.reminder(key="expired-event|0")
        now = datetime.now(timezone.utc)
        legacy = {recent["key"]: now.isoformat(), expired["key"]: (now - timedelta(hours=13)).isoformat(),
                  "bad-event": "invalid timestamp"}
        self.assert_success(self.call(legacy, arguments=("--migrate",)))
        self.assertEqual(self.state_dir.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(json.loads(self.state.read_bytes())), [hashlib.sha256(recent["key"].encode()).hexdigest()])
        self.assert_success(self.call(recent))
        self.assertTrue(self.messages.empty())
        self.assert_success(self.call(expired))
        self.assertEqual(self.capture()["data"][3], expired["headline"])

    def test_invalid_input_and_unsafe_state_fail_without_delivery(self):
        for body in (b"[]", b"\xff", b" " * 32769, self.reminder(link="https://example.test/?q=&lt;tag&gt;")):
            result = self.call(body)
            self.assertEqual((result.returncode, result.stdout), (64, b""))
        outside = self.root / "outside"
        outside.mkdir()
        self.state_dir.symlink_to(outside)
        result = self.call(self.reminder())
        self.assertEqual((result.returncode, result.stdout), (74, b""))
        self.assertEqual(list(outside.iterdir()), [])
        self.assertTrue(self.messages.empty())

    def test_unavailable_session_or_service_does_not_mark_delivered(self):
        reminder = self.reminder()
        for address in ("", f"unix:path={self.root / 'missing-bus'}", "tcp:host=localhost,port=1"):
            result = self.call(reminder, env={**self.env, "DBUS_SESSION_BUS_ADDRESS": address})
            self.assertEqual((result.returncode, result.stdout), (69, b""), result.stderr)
            self.assertFalse(self.state.exists())
        result = self.call(reminder, command=["dbus-run-session", "--", str(HELPER)])
        self.assertEqual((result.returncode, result.stdout), (69, b""), result.stderr)
        self.assertFalse(self.state.exists())
        self.assert_success(self.call(reminder))
        self.assertEqual(self.capture()["data"][3], reminder["headline"])

    def test_notification_errors_and_timeouts_never_log_or_record_payload(self):
        for headline in (ERROR_HEADLINE, TIMEOUT_HEADLINE):
            reminder = self.reminder(headline=headline)
            started = time.monotonic()
            result = self.call(reminder)
            elapsed = time.monotonic() - started
            self.assertEqual((result.returncode, result.stdout), (1, b""))
            self.assertEqual(result.stderr, b"calendar-notify: Could not reach the desktop notification service.\n")
            self.assertEqual(self.capture()["data"][3], headline)
            self.assertFalse(self.state.exists())
            if headline == TIMEOUT_HEADLINE:
                self.assertLess(elapsed, 5)
        reminder = self.reminder()
        self.assert_success(self.call(reminder))
        self.assertEqual(self.capture()["data"][3], reminder["headline"])


if __name__ == "__main__":
    if sys.argv[1:] == ["serve"]:
        serve_notifications()
    else:
        unittest.main()
