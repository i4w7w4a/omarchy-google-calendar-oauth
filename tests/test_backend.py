"""Exercise the CLI and queue in temporary profiles without Google requests."""

import json
import hashlib
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["TEST_ROOT"])
mode = os.environ.get("TEST_MODE", "success")
args = sys.argv[1:]
if args == ["config", "--json"]:
    print(json.dumps({"config": {"calendar_dir": str(root / "data"), "default_calendar": "test"}}))
    raise SystemExit()
if args[:2] == ["--json", "events"]:
    print("[]")
    raise SystemExit()
(root / "commands.log").open("a").write(json.dumps(args) + "\n")
if args[0] == "pull":
    print("📅 test\n   No changes to pull")
    raise SystemExit()
if mode == "offline":
    print("Google connection is unavailable", file=sys.stderr)
    raise SystemExit(1)
if mode == "slow":
    time.sleep(2)
plan_path = Path(os.environ["OMARCHY_CALENDAR_PUSH_PLAN"])
plan = json.loads(plan_path.read_text())
receipt = plan_path.with_suffix(".json.receipt")
assert plan["google_account"] == "test@example.invalid"
assert plan["google_calendar_id"] == "test@example.invalid"
print("📅 test")
changes = json.loads((root / "state/omarchy-calendar/pending.json").read_text())["calendars"]["test"]["changes"]
processed = 0
for filename, change in changes.items():
    action = "delete_event" if change["after"] is None else ("create_event" if change["before"] is None else "update_event")
    row = {"uid":change["uid"], "recurrence":change["recurrence"], "action":action}
    assert row in plan["allow"]
    with receipt.open("a") as log:
        log.write(json.dumps({**row, "status":"started"}) + "\n")
        if mode == "ambiguous":
            print("Calendar operation timed out; remote result may be incomplete", file=sys.stderr)
            raise SystemExit(1)
        if mode == "partial" and processed:
            log.write(json.dumps({**row, "status":"error"}) + "\n")
            print("   failed to update event")
            break
        log.write(json.dumps({**row, "status":"success"}) + "\n")
    processed += 1
    if change["after"] is not None:
        (root / "data/test/.caldir/state/bases" / filename).write_bytes((root / "data/test" / filename).read_bytes())
if processed:
    print("Pushed: 1 created, 0 updated, 0 deleted")
'''


class Backend(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="calendar-backend-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "scripts"
        shutil.copytree(SCRIPTS, self.scripts, ignore=shutil.ignore_patterns("__pycache__"))
        (self.scripts / "calendar-caldir").write_text(MOCK)
        self.path = self.root / "data/test"
        self.bases = self.path / ".caldir/state/bases"
        self.bases.mkdir(parents=True)
        self.configure()
        self.state = self.root / "state/omarchy-calendar"
        self.env = dict(os.environ, TEST_ROOT=str(self.root), XDG_STATE_HOME=str(self.root / "state"),
                        TZ="Europe/Berlin", PYTHONDONTWRITEBYTECODE="1", PATH="/usr/bin:/bin")
        executable = self.root / "omarchy-shell"
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        self.env["PATH"] = str(self.root) + ":" + self.env["PATH"]

    def configure(self, google=True):
        remote = '\n[remote]\nprovider="google"\ngoogle_account="test@example.invalid"\ngoogle_calendar_id="test@example.invalid"\n'
        (self.path / ".caldir/config.toml").write_text('name="Test"\ncolor="#abcdef"\nread_only=false\n' + (remote if google else ""))

    def call(self, script, *args, payload=None, mode="success"):
        return subprocess.run([str(self.scripts / script), *args], text=True, capture_output=True,
                              input=json.dumps(payload) if payload is not None else "", timeout=12,
                              env={**self.env, "TEST_MODE": mode})

    def create(self, **details):
        payload = {"title": "Meeting", "date": "2027-03-28", "time": "01:45", "repeat": "none", **details}
        process = self.call("calendar-create", "--stdin", payload=payload)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        return json.loads(process.stdout)

    def edit(self, uid, **details):
        payload = {"action": "edit", "scope": "series", "calendar": "test", "uid": uid,
                   "all_day": False, "title": "Updated", "time": "01:45", "recurrence_rule": "keep", **details}
        return self.call("calendar-mutate", "--stdin", payload=payload)

    def delete(self, uid):
        return self.call("calendar-mutate", "--stdin", payload={"action": "delete", "scope": "series",
                         "calendar": "test", "uid": uid, "confirm": True})

    def push(self, *args, mode="success"):
        return self.call("calendar-push", *(args or ("--auto",)), mode=mode)

    def pending(self):
        return json.loads((self.state / "pending.json").read_text())

    def commands(self):
        log = self.root / "commands.log"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def synced(self, uid, **fields):
        path = self.path / (uid + ".ics")
        text = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\n"
                f"UID:{uid}\r\nDTSTAMP:20270101T000000Z\r\n"
                "DTSTART;TZID=Europe/Berlin:20270328T014500\r\n"
                "DTEND;TZID=Europe/Berlin:20270328T034500\r\n"
                "SUMMARY:Old\r\nX-GOOGLE-EVENT-ID:abc123\r\n"
                + "".join(f"{key}:{value}\r\n" for key, value in fields.items())
                + "END:VEVENT\r\nEND:VCALENDAR\r\n")
        path.write_bytes(text.encode())
        (self.bases / path.name).write_bytes(text.encode())
        return path

    def test_created_duration_reminder_and_escaping(self):
        result = self.create(title="Встреча; план, \\ тест", description="line 1\nline 2", duration_minutes=75,
                             reminder={"mode": "custom", "minutes": 17}, repeat="weekly", count=3)
        self.assertEqual(result["sync"], "pending")
        self.assertEqual(self.commands(), [])
        ics = next(self.path.glob("*.ics")).read_text()
        for field in ("DTSTART;TZID=Europe/Berlin:20270328T014500", "DTEND;TZID=Europe/Berlin:20270328T040000",
                      "RRULE:FREQ=WEEKLY;COUNT=3", "TRIGGER;RELATED=START:-PT17M", r"DESCRIPTION:line 1\nline 2",
                      r"SUMMARY:Встреча\; план\, \\ тест"):
            self.assertIn(field, ics)

    def test_zero_reminder_and_duration_are_rejected_before_writes(self):
        for details in ({"reminder": {"mode": "custom", "minutes": 0}}, {"duration_minutes": 0}):
            invalid = self.call("calendar-create", "--stdin", payload={"title":"a", "date":"2027-03-28",
                                "time":"01:45", **details})
            self.assertEqual(invalid.returncode, 64)
        self.assertFalse(list(self.path.glob("*.ics")))

    def test_local_keep_preserves_nested_alarm_and_non_editor_fields(self):
        self.configure(google=False)
        path = self.synced("uid", LOCATION="Office", **{"X-EXTENSION":"Vendor data"})
        path.write_bytes(path.read_bytes().replace(b"END:VEVENT", b"BEGIN:VALARM\r\nACTION:EMAIL\r\nSUMMARY:Alarm title\r\nDESCRIPTION:Alarm body\r\nTRIGGER:-PT2H\r\nEND:VALARM\r\nEND:VEVENT"))
        result = self.edit("uid", description="new body", duration_minutes=90, reminder={"mode":"keep"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        contents = path.read_text()
        self.assertIn("X-EXTENSION:Vendor data", contents)
        self.assertIn("LOCATION:Office", contents)
        self.assertIn("SUMMARY:Alarm title\nDESCRIPTION:Alarm body\nTRIGGER:-PT2H", contents)
        self.assertIn("DTEND;TZID=Europe/Berlin:20270328T041500", contents)

    def test_reminder_default_none_custom_and_stale_revision(self):
        path = self.synced("uid", **{"X-GOOGLE-DEFAULT-REMINDERS":"TRUE"})
        stale = self.edit("uid", expected_revision="0" * 64)
        self.assertEqual(stale.returncode, 75, stale.stdout + stale.stderr)
        self.assertEqual(json.loads(stale.stdout)["reason"], "stale_revision")
        for reminder, expected, absent in (({"mode":"none"}, "SUMMARY:Updated", "X-GOOGLE-DEFAULT-REMINDERS"),
                                           ({"mode":"custom", "minutes":40320}, "TRIGGER;RELATED=START:-PT40320M", "X-GOOGLE-DEFAULT-REMINDERS"),
                                           ({"mode":"default"}, "X-GOOGLE-DEFAULT-REMINDERS:TRUE", "BEGIN:VALARM")):
            result = self.edit("uid", reminder=reminder)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(expected, path.read_text())
            self.assertNotIn(absent, path.read_text())

    def test_instance_duration_and_series_duration_are_independent(self):
        path = self.synced("series", RRULE="FREQ=WEEKLY;COUNT=4")
        occurrence = self.edit("series", scope="instance", instance_id="series__TZID=Europe/Berlin:20270404T014500",
                               duration_minutes=33, reminder={"mode":"custom", "minutes":5})
        self.assertEqual(occurrence.returncode, 0, occurrence.stdout + occurrence.stderr)
        override = next(self.path.glob("override-*.ics"))
        self.assertIn("RECURRENCE-ID;TZID=Europe/Berlin:20270404T014500", override.read_text())
        self.assertIn("DTEND;TZID=Europe/Berlin:20270404T021800", override.read_text())
        self.assertNotIn("RRULE:", override.read_text())
        edited = self.edit("series", duration_minutes=80)
        self.assertEqual(edited.returncode, 0, edited.stdout + edited.stderr)
        self.assertIn("DTEND;TZID=Europe/Berlin:20270328T040500", path.read_text())
        self.assertIn("DTEND;TZID=Europe/Berlin:20270404T021800", override.read_text())

    def test_offline_then_retry_exact_queued_create(self):
        result = self.create()
        self.assertEqual(self.push(mode="offline").returncode, 1)
        pending = self.pending()
        self.assertEqual(pending["pending_count"], 1)
        self.assertTrue(pending["auto_retry"])
        self.assertGreater(pending["retry_at"], time.time())
        self.assertEqual(self.call("calendar-pull", "--pending").returncode, 75)
        self.assertEqual(len(self.commands()), 1)
        retried = self.push("--confirm", "--json")
        self.assertEqual(retried.returncode, 0, retried.stdout + retried.stderr)
        self.assertEqual(json.loads(retried.stdout)["sync"], "synced")
        self.assertEqual(self.pending()["pending_count"], 0)
        self.assertEqual(len(list(self.path.glob("*.ics"))), 1)
        self.assertEqual(json.loads(self.push().stdout)["sync"], "idle")
        self.assertEqual(len(self.commands()), 2)
        self.assertEqual(self.commands()[0][1:3], ["--calendar", "test"])
        self.assertIn(result["uid"], next(self.path.glob("*.ics")).read_text())

    def test_partial_success_keeps_only_unconfirmed_edits(self):
        self.synced("one")
        self.synced("two")
        self.assertEqual(self.edit("one", duration_minutes=45).returncode, 0)
        self.assertEqual(self.edit("two", duration_minutes=90).returncode, 0)
        partial = self.push(mode="partial")
        self.assertEqual(partial.returncode, 1, partial.stdout + partial.stderr)
        changes = self.pending()["calendars"]["test"]["changes"]
        self.assertEqual({item["uid"] for item in changes.values()}, {"two"})
        self.assertEqual(self.push("--confirm", "--json").returncode, 0)
        self.assertEqual(self.pending()["pending_count"], 0)

    def test_ambiguous_create_cannot_be_sent_or_locally_dropped_twice(self):
        created = self.create()
        ambiguous = self.push(mode="ambiguous")
        self.assertEqual(ambiguous.returncode, 1, ambiguous.stdout + ambiguous.stderr)
        self.assertFalse(self.pending()["auto_retry"])
        self.assertEqual(self.pending()["pending_count"], 1)
        self.assertEqual(self.push("--confirm", "--json").returncode, 1)
        self.assertEqual(self.delete(created["uid"]).returncode, 75)
        self.assertEqual(self.call("calendar-pull", "--pending").returncode, 75)
        self.assertEqual(len(self.commands()), 1)
        self.assertEqual(len(list(self.path.glob("*.ics"))), 1)

    def test_completed_delete_receipt_survives_interrupted_helper(self):
        self.synced("one")
        self.assertEqual(self.delete("one").returncode, 0)
        queue = self.pending()
        attempt = "1" * 32
        queue["calendars"]["test"]["attempt"] = attempt
        directory = self.state / "attempts" / attempt
        directory.mkdir(parents=True)
        row = {"action":"delete_event", "uid":"one", "recurrence":""}
        (directory / "plan.json.receipt").write_text("\n".join(json.dumps({**row, "status": status})
                                                               for status in ("started", "success")) + "\n")
        (self.state / "pending.json").write_text(json.dumps(queue))
        recovered = self.push()
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        self.assertEqual(json.loads(recovered.stdout)["sync"], "synced")
        self.assertEqual(self.commands(), [])
        self.assertFalse((self.bases / "one.ics").exists())

    def test_provider_unsupported_keep_is_rejected_before_google_update(self):
        path = self.synced("uid")
        unsupported = path.read_bytes().replace(b"END:VEVENT", b"BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:PT0S\r\nEND:VALARM\r\nEND:VEVENT")
        path.write_bytes(unsupported)
        (self.bases / path.name).write_bytes(unsupported)
        result = self.edit("uid", reminder={"mode":"keep"})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("cannot preserve", json.loads(result.stdout)["error"])
        self.assertEqual(path.read_bytes(), unsupported)
        self.assertEqual(self.edit("uid", reminder={"mode":"custom", "minutes":7}).returncode, 0)

    def test_status_output_distinguishes_normal_changes_from_diagnostics(self):
        for sample, expected in (("   Local changes (to push):", True), ("   No changes to push", True),
                                 ("   ~ event changed", True), ("   failed to update event", False),
                                 ("   You are about to delete many events!", False)):
            self.assertEqual(self.call("calendar-push", "--auto").returncode, 0)
            code = ("from calendar_sync import DIAGNOSTIC;import sys;"
                    "print(bool(DIAGNOSTIC.match(sys.argv[1])))")
            output = subprocess.check_output(["python", "-c", code, sample], text=True,
                                             env={**self.env, "PYTHONPATH":str(self.scripts)})
            self.assertEqual(output.strip() == "False", expected)

    def test_out_of_band_deletion_is_never_pushed(self):
        stale = self.synced("other")
        self.synced("mine")
        stale.unlink()
        self.assertEqual(self.call("calendar-pull", "--pending").returncode, 0)
        self.assertEqual(self.edit("mine", duration_minutes=45).returncode, 0)
        self.assertEqual(self.push().returncode, 1)
        self.assertEqual(self.commands(), [["pull"]])

    def test_confirmed_delete_and_lock(self):
        path = self.synced("one")
        self.synced("two")
        self.assertEqual(self.delete("one").returncode, 0)
        self.assertFalse(path.exists())
        running = subprocess.Popen([str(self.scripts / "calendar-push"), "--auto"], env={**self.env, "TEST_MODE":"slow"},
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(100):
                if self.commands():
                    break
                time.sleep(.02)
            self.assertEqual(self.call("calendar-pull", "--pending").returncode, 75)
            self.assertEqual(self.edit("two", duration_minutes=35).returncode, 75)
            out, err = running.communicate(timeout=10)
            self.assertEqual(running.returncode, 0, out + err)
        finally:
            if running.poll() is None:
                running.kill()
                running.communicate()
        self.assertFalse((self.bases / path.name).exists())
        self.assertEqual(self.edit("two", duration_minutes=35).returncode, 0)
        self.assertEqual(self.push().returncode, 0)

    def test_cancelled_push_terminates_wrapper_before_unlock(self):
        self.create()
        running = subprocess.Popen([str(self.scripts / "calendar-push"), "--auto"], env={**self.env, "TEST_MODE":"slow"},
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(100):
                if self.commands():
                    break
                time.sleep(.02)
            self.assertTrue(self.commands())
            running.terminate()
            out, err = running.communicate(timeout=5)
            self.assertEqual(running.returncode, 1, out + err)
            self.assertEqual(self.pending()["pending_count"], 1)
            self.assertTrue(self.pending()["auto_retry"])
            self.assertEqual(list(self.bases.iterdir()), [])
            self.assertEqual(self.push("--confirm", "--json").returncode, 0)
        finally:
            if running.poll() is None:
                running.kill()
                running.communicate()

    def test_private_cache_works_with_real_pinned_caldir(self):
        binary_path = os.environ.get("TEST_CALDIR_BIN_DIR")
        if not binary_path:
            self.skipTest("Set TEST_CALDIR_BIN_DIR to the verified Caldir 0.14.9 binary directory")
        config = self.root / "config/omarchy-calendar/caldir"
        data = self.root / "runtime-data/omarchy-calendar"
        config.mkdir(parents=True)
        (data / "bin").mkdir(parents=True)
        self.path = data / "calendars/test"
        (self.path / ".caldir").mkdir(parents=True)
        self.configure(google=False)
        for name in ("caldir", "caldir-provider-google"):
            shutil.copy2(Path(binary_path) / name, data / "bin" / name)
        (config / "config.toml").write_text(f'calendar_dir = "{self.path.parent}"\ndefault_calendar="test"\n')
        shutil.copy2(SCRIPTS / "calendar-caldir", self.scripts / "calendar-caldir")
        self.env.update(XDG_CONFIG_HOME=str(self.root / "config"), XDG_DATA_HOME=str(self.root / "runtime-data"))
        self.create(repeat="weekly", count=3, duration_minutes=75, reminder={"mode":"custom", "minutes":17})
        process = self.call("calendar-events", "2027-03-28", "2027-04-15")
        events = json.loads(process.stdout)["events"]
        self.assertEqual(len(events), 3)
        for event in events:
            start, end = (datetime.fromisoformat(event[key]) for key in ("start", "end"))
            self.assertEqual((end - start).total_seconds(), 75 * 60)
            self.assertEqual(event["series_duration_minutes"], 75)
            self.assertEqual(event["reminder"], {"mode":"custom", "minutes":17})
            self.assertEqual(len(event["revision"]), 64)

    def test_pinned_caldir_with_gated_fake_provider(self):
        binary_dir = os.environ.get("TEST_CALDIR_BIN_DIR")
        if not binary_dir:
            self.skipTest("Set TEST_CALDIR_BIN_DIR to the verified Caldir 0.14.9 binary directory")
        config = self.root / "caldir-config/caldir"
        config.mkdir(parents=True)
        (config / "config.toml").write_text(f'calendar_dir="{self.path.parent}"\ndefault_calendar="test"\n')
        proxy = self.root / "proxy"
        proxy.mkdir()
        (proxy / "caldir-provider-google").symlink_to(SCRIPTS / "calendar-provider-gate")
        fake = self.root / "provider"
        fake.write_text('''#!/usr/bin/python3
import json, os, re, sys
from pathlib import Path
store = Path(os.environ["TEST_ROOT"]) / "fake-remote.json"
for line in sys.stdin:
    obj = json.loads(line)
    method, args = obj["command"], obj["params"]
    values = json.loads(store.read_text()) if store.exists() else {}
    if method == "list_events":
        data = list(values.values())
    else:
        event = args["event"]
        uid = re.search(r"(?m)^UID:([^\\r\\n]+)", event)[1]
        if method == "create_event" and os.environ.get("TEST_MODE") == "definitive_rejection":
            print(json.dumps({"status":"error", "error":"Google rejected event creation (HTTP 429)"}), flush=True)
            continue
        if method == "delete_event":
            values.pop(uid)
            data = None
        else:
            if method == "create_event":
                assert uid not in values, "duplicate create"
                event = event.replace("END:VEVENT", "X-GOOGLE-EVENT-ID:provider123\\r\\nEND:VEVENT")
            else:
                assert uid in values
            values[uid] = event
            data = event
        store.write_text(json.dumps(values))
    print(json.dumps({"status":"success", "data":data}), flush=True)
''')
        fake.chmod(0o755)
        wrapper = self.scripts / "calendar-caldir"
        wrapper.write_text(f'''#!/bin/sh
export XDG_CONFIG_HOME="{config.parent}"
export PATH="{proxy}"
export OMARCHY_CALENDAR_REAL_GOOGLE_PROVIDER="{fake}"
exec "{Path(binary_dir) / 'caldir'}" "$@"
''')
        created = self.create(duration_minutes=75, reminder={"mode":"custom", "minutes":17})
        rejected = self.push(mode="definitive_rejection")
        self.assertEqual(rejected.returncode, 1, rejected.stdout + rejected.stderr)
        self.assertTrue(self.pending()["auto_retry"])
        self.assertEqual(self.pending()["pending_count"], 1)
        push = self.push("--confirm", "--json")
        self.assertEqual(push.returncode, 0, push.stdout + push.stderr)
        self.assertEqual(self.pending()["pending_count"], 0)
        uid = created["uid"]
        current = json.loads((self.root / "fake-remote.json").read_text())
        self.assertIn("TRIGGER;RELATED=START:-PT17M", current[uid])
        self.assertEqual(self.edit(uid, title="Changed offline").returncode, 0)
        self.assertEqual(self.edit(uid, title="Meeting").returncode, 0)
        reverted = self.push()
        self.assertEqual(reverted.returncode, 0, reverted.stdout + reverted.stderr)
        self.assertEqual(self.pending()["pending_count"], 0)
        self.assertEqual(json.loads((self.root / "fake-remote.json").read_text()), current)
        edited = self.edit(uid, duration_minutes=80, reminder={"mode":"none"})
        self.assertEqual(edited.returncode, 0, edited.stdout + edited.stderr)
        push = self.push()
        self.assertEqual(push.returncode, 0, push.stdout + push.stderr)
        current = json.loads((self.root / "fake-remote.json").read_text())
        self.assertNotIn("BEGIN:VALARM", current[uid])
        self.assertEqual(self.delete(uid).returncode, 0)
        push = self.push()
        self.assertEqual(push.returncode, 0, push.stdout + push.stderr)
        self.assertEqual(self.pending()["pending_count"], 0)
        self.assertEqual(json.loads((self.root / "fake-remote.json").read_text()), {})
        self.assertFalse((self.bases / (hashlib.sha256(uid.encode()).hexdigest() + ".ics")).exists())


if __name__ == "__main__":
    unittest.main()
