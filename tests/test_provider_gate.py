import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "owner@example.test"
CALENDAR = "calendar@example.test"
UID = "requested@example.test"
RID = "2026-11-13T09:00:00+00:00"


def event(uid, recurrence=""):
    return "\r\n".join(filter(None, (
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:CALDIR", "BEGIN:VEVENT",
        f"UID:{uid}", recurrence, "DTSTART:20261113T090000Z",
        "SUMMARY:Example", "END:VEVENT", "END:VCALENDAR",
    ))) + "\r\n"


class ProviderGateTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.provider = self.root / "provider"
        self.provider.write_text("""#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys

assert 'OMARCHY_CALENDAR_PUSH_PLAN' not in os.environ
assert 'OMARCHY_CALENDAR_REAL_GOOGLE_PROVIDER' not in os.environ
request = json.load(sys.stdin)
with Path(os.environ['GATE_FIXTURE_REQUESTS']).open('a') as target:
    target.write(json.dumps(request) + '\\n')
command = request['command']
if os.environ.get('GATE_FIXTURE_MODE') == 'error':
    print(json.dumps({'status': 'error', 'error': 'fixture failure'}))
elif os.environ.get('GATE_FIXTURE_MODE') == 'invalid':
    print(json.dumps({'status': 'success', 'data': None}))
elif os.environ.get('GATE_FIXTURE_MODE') == 'wait':
    import time
    Path(os.environ['GATE_FIXTURE_PID']).write_text(str(os.getpid()))
    time.sleep(30)
else:
    value = [] if command.startswith('list_') else (None if command == 'delete_event' else request['params']['event'])
    print(json.dumps({'status': 'success', 'data': value}))
""")
        self.provider.chmod(0o700)
        self.requests = self.root / "requests.jsonl"
        self.plan = self.root / "plan.json"
        self.receipt = self.root / "plan.json.receipt"
        self.child_pid = self.root / "provider.pid"
        self.gate = self.root / "caldir-provider-google"
        self.gate.symlink_to(ROOT / "scripts/calendar-provider-gate")
        self.env = {
            **os.environ,
            "PATH": str(self.root),
            "OMARCHY_CALENDAR_PUSH_PLAN": str(self.plan),
            "OMARCHY_CALENDAR_REAL_GOOGLE_PROVIDER": str(self.provider),
            "GATE_FIXTURE_REQUESTS": str(self.requests),
            "GATE_FIXTURE_PID": str(self.child_pid),
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def authorize(self, *intents):
        self.plan.write_text(json.dumps({
            "google_account": ACCOUNT,
            "google_calendar_id": CALENDAR,
            "allow": [
                {"action": action, "uid": uid, "recurrence": recurrence}
                for action, uid, recurrence in intents
            ],
        }))
        self.plan.chmod(0o600)

    def rpc(self, action, *, calendar=CALENDAR, account=ACCOUNT, ics=None, mode=None):
        parameters = {"google_account": account, "google_calendar_id": calendar}
        if ics is not None:
            parameters["event"] = ics
        env = self.env.copy()
        if mode:
            env["GATE_FIXTURE_MODE"] = mode
        result = subprocess.run(
            [str(self.gate)], input=json.dumps({"command": action, "params": parameters}) + "\n",
            env=env, capture_output=True, text=True, check=True, timeout=5,
        )
        return json.loads(result.stdout)

    def records(self, path):
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_reads_forward_without_a_push_plan(self):
        self.assertEqual(self.rpc("list_events"), {"status": "success", "data": []})
        self.assertEqual(self.rpc("list_calendars"), {"status": "success", "data": []})
        self.assertEqual([row["command"] for row in self.records(self.requests)], ["list_events", "list_calendars"])
        self.assertFalse(self.receipt.exists())

    def test_rejects_unqueued_deletion_wrong_operation_calendar_account_and_occurrence(self):
        self.authorize(("update_event", UID, RID))
        zoned = event(UID, "RECURRENCE-ID;TZID=Europe/Moscow:20261113T120000")
        wrong_day = event(UID, "RECURRENCE-ID:20261114T090000Z")
        for action, ics, account, calendar in (
            ("delete_event", event("restored@example.test"), ACCOUNT, CALENDAR),
            ("delete_event", zoned, ACCOUNT, CALENDAR),
            ("update_event", zoned, "different@example.test", CALENDAR),
            ("update_event", zoned, ACCOUNT, "different@example.test"),
            ("update_event", wrong_day, ACCOUNT, CALENDAR),
        ):
            self.assertEqual(self.rpc(action, ics=ics, account=account, calendar=calendar)["status"], "error")
        self.assertEqual(self.records(self.requests), [])
        self.assertEqual([row["status"] for row in self.records(self.receipt)], ["rejected"] * 5)

    def test_authorized_occurrence_and_deletion_emit_exact_receipts(self):
        gone = "deleted@example.test"
        self.authorize(("update_event", UID, RID), ("delete_event", gone, ""))
        zoned = event(UID, "RECURRENCE-ID;TZID=Europe/Moscow:20261113T120000")
        self.assertEqual(self.rpc("update_event", ics=zoned), {"status": "success", "data": zoned})
        self.assertEqual(self.rpc("delete_event", ics=event(gone)), {"status": "success", "data": None})
        self.assertEqual(self.records(self.receipt), [
            {"action": action, "uid": uid, "recurrence": recurrence, "status": status}
            for action, uid, recurrence in (("update_event", UID, RID), ("delete_event", gone, ""))
            for status in ("started", "success")
        ])
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o600)

    def test_nonexistent_and_ambiguous_zoned_occurrences_never_reach_provider(self):
        self.authorize(("update_event", UID, "2026-03-29T01:30:00+00:00"),
                       ("update_event", UID, "2026-10-25T00:30:00+00:00"))
        for local_time in ("20260329T023000", "20261025T023000"):
            with self.subTest(local_time=local_time):
                ics = event(UID, "RECURRENCE-ID;TZID=Europe/Berlin:" + local_time)
                self.assertEqual(self.rpc("update_event", ics=ics)["status"], "error")
        self.assertFalse(self.requests.exists())

    def test_failed_create_keeps_started_record_and_disallows_second_write(self):
        self.authorize(("create_event", UID, ""), ("update_event", UID, ""))
        self.assertEqual(self.rpc("create_event", ics=event(UID), mode="error"),
                         {"status": "error", "error": "fixture failure"})
        self.assertEqual(self.rpc("create_event", ics=event(UID))["status"], "error")
        self.assertEqual(self.rpc("update_event", ics=event(UID))["status"], "error")
        self.assertEqual([row["status"] for row in self.records(self.receipt)],
                         ["started", "error", "rejected", "rejected"])
        self.assertEqual(len(self.records(self.requests)), 1)

    def test_malformed_success_remains_uncertain(self):
        self.authorize(("create_event", UID, ""))
        self.assertEqual(self.rpc("create_event", ics=event(UID), mode="invalid")["status"], "error")
        self.assertEqual([row["status"] for row in self.records(self.receipt)], ["started", "error"])

    def test_provider_is_stopped_when_caldir_kills_its_proxy(self):
        self.authorize(("create_event", UID, ""))
        request = {"command": "create_event", "params": {
            "google_account": ACCOUNT, "google_calendar_id": CALENDAR, "event": event(UID),
        }}
        env = {**self.env, "GATE_FIXTURE_MODE": "wait"}
        with subprocess.Popen([str(self.gate)], env=env, stdin=subprocess.PIPE) as proxy:
            try:
                proxy.stdin.write(json.dumps(request).encode() + b"\n")
                proxy.stdin.close()
                deadline = time.monotonic() + 3
                while not self.child_pid.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                child = Path("/proc") / self.child_pid.read_text() / "stat"
                self.assertTrue(child.exists())
                self.assertEqual([row["status"] for row in self.records(self.receipt)], ["started"])
            finally:
                proxy.kill()
                proxy.wait(timeout=3)

        def child_stopped():
            try:
                return child.read_text().rsplit(")", 1)[1].split()[0] == "Z"
            except FileNotFoundError:
                return True

        deadline = time.monotonic() + 3
        while not child_stopped() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(child_stopped())
        self.assertEqual([row["status"] for row in self.records(self.receipt)], ["started"])

    def test_missing_unsafe_or_duplicate_input_does_not_dispatch(self):
        self.assertEqual(self.rpc("connect")["status"], "error")
        self.assertEqual(self.rpc("create_event", ics=event(UID))["status"], "error")
        self.authorize(("create_event", UID, ""))
        self.plan.chmod(0o644)
        self.assertEqual(self.rpc("create_event", ics=event(UID))["status"], "error")
        self.plan.chmod(0o600)
        duplicate = event(UID).replace("SUMMARY:", "UID:other@example.test\r\nSUMMARY:")
        self.assertEqual(self.rpc("create_event", ics=duplicate)["status"], "error")
        self.assertFalse(self.requests.exists())


if __name__ == "__main__":
    unittest.main()
