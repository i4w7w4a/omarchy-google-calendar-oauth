"""Serialize the private Caldir, journal plugin mutations and push only authorized changes."""

from __future__ import annotations

import hashlib
import json
import os
import re
import time
from datetime import date, datetime, timedelta, timezone
from uuid import uuid4

from calendar_store import (
    CalendarError, CaldirTimeout, MAX_CACHE_BYTES, MAX_ICS_BYTES, PENDING_FILE, PROVIDER_ID, STATE_DIR,
    atomic_json, atomic_write, caldir, calendar_directory, calendar_settings, config,
    encode_ics, event_bounds, event_files, event_identity, event_time, instance_identity, is_date,
    is_google, property_indexes, property_line, property_name, property_value, read_bounded, read_lines, sync_directory,
    unfold,
)

INVENTORY_FILE = STATE_DIR / "inventory.json"
DIAGNOSTIC = re.compile(r"^   (?![ +~-]|No changes(?: to (?:push|pull))?$|(?:Local|Remote) changes \(to (?:push|pull)\):$)\S")


def read_state(path, default):
    try:
        value = json.loads(read_bounded(path, MAX_CACHE_BYTES))
    except FileNotFoundError:
        return default
    except (ValueError, RecursionError) as error:
        raise CalendarError("The private calendar sync state is invalid") from error
    if not isinstance(value, dict):
        raise CalendarError("The private calendar sync state is invalid")
    return value


def load_queue():
    state = read_state(PENDING_FILE, {"version": 1, "calendars": {}})
    if (state.get("version") != 1 or not isinstance(state.get("calendars"), dict)
            or any(not isinstance(entry, dict) or not isinstance(entry.get("changes"), dict)
                   for entry in state["calendars"].values())):
        raise CalendarError("The calendar queue is invalid")
    return state


def save_queue(state):
    entries = state["calendars"].values()
    retryable = [entry for entry in entries if entry.get("attempt") or not entry.get("uncertain")]
    state["pending_count"] = sum(len(entry["changes"]) for entry in entries)
    state["auto_retry"] = state["pending_count"] > 0 and bool(retryable)
    state["retry_at"] = min((entry.get("retry_at", 0) for entry in retryable), default=0)
    atomic_json(PENDING_FILE, state)


def digest(contents):
    return hashlib.sha256(contents).hexdigest() if contents is not None else None


def file_digest(path):
    try:
        return digest(read_bounded(path, MAX_ICS_BYTES))
    except FileNotFoundError:
        return None


def calendar_fingerprints(path):
    return {file.name: file_digest(file) for file in event_files(path)}


def existing_calendar_paths(root):
    return (path for path in sorted(root.iterdir()) if path.is_dir() and not path.is_symlink()
            and (path / ".caldir/config.toml").is_file()) if root.is_dir() else ()


def calendar_remote(settings):
    return {key: settings.get("remote", {}).get(key) for key in ("provider", "google_account", "google_calendar_id")}


def synced_ids(path):
    state = path / ".caldir/state"
    identities = {event_identity(read_lines(base)) for base in event_files(state / "bases")}
    try:
        legacy = read_bounded(state / "known_event_ids", MAX_CACHE_BYTES).decode().splitlines()
    except FileNotFoundError:
        return identities
    for value in legacy:
        uid, separator, rid = value.strip().rpartition("__")
        if separator:
            try:
                identities.add(instance_identity(uid, rid))
                continue
            except CalendarError:
                pass
        if value.strip():
            identities.add((value.strip(), ""))
    return identities


def local_ids(path):
    return {event_identity(read_lines(file)) for file in event_files(path)}


def initial_inventory(path):
    # A pre-existing private profile can have pulled Caldir events already.
    # Only exact matches to its sync bases are initially authorized.
    bases = path / ".caldir/state/bases"
    base_fingerprints = set()
    for base in event_files(bases):
        base_fingerprints.add(sync_fingerprint(read_lines(base)))
    return {file.name: file_digest(file) for file in event_files(path)
            if sync_fingerprint(read_lines(file)) in base_fingerprints}


def content_fingerprint(lines):
    return digest(encode_ics([line for line in lines if not line.upper().startswith("DTSTAMP:")]))


def sync_fingerprint(lines):
    """Compare VEVENT data while ignoring revision fields ignored by Caldir."""
    ignored = {"DTSTAMP", "LAST-MODIFIED", "SEQUENCE"}
    start, end = event_bounds(lines)
    properties = list(property_indexes(lines))
    top_level = set(properties)
    body = sorted(lines[index] for index in properties if property_name(lines[index]) not in ignored)
    children = [lines[index] for index in range(start + 1, end) if index not in top_level]
    return digest(encode_ics(body + children))


def remove_synced_ids(path, removed):
    """Forget a confirmed deletion so restoring it remotely is a new pull."""
    if not removed:
        return
    state = path / ".caldir/state"
    ids_file = state / "known_event_ids"
    try:
        legacy = read_bounded(ids_file, MAX_CACHE_BYTES).decode().splitlines()
    except FileNotFoundError:
        legacy = []
    kept = []
    for value in legacy:
        uid, separator, rid = value.rpartition("__")
        identity = (value, "")
        if separator:
            try:
                identity = instance_identity(uid, rid)
            except CalendarError:
                pass
        if identity not in removed:
            kept.append(value)
    if kept != legacy:
        atomic_write(ids_file, "\n".join(kept).encode())
    for file in event_files(state / "bases"):
        if event_identity(read_lines(file)) in removed:
            file.unlink()
            sync_directory(file.parent)


def refresh_inventory(path, settings, *, deleted=(), previous_ids=None, complete_pull=False):
    inventory = read_state(INVENTORY_FILE, {})
    remote = calendar_remote(settings)
    removed = set(deleted)
    present = local_ids(path)
    if complete_pull and previous_ids is not None:
        # Only disappearance during a successful plugin pull is trusted. A
        # file already absent when the pull began may have been removed by hand.
        removed.update(previous_ids - present)
    remove_synced_ids(path, removed - present)
    inventory[path.name] = {"remote": remote, "files": initial_inventory(path)}
    atomic_json(INVENTORY_FILE, inventory)


def date_bounds(lines):
    days = []
    for name in ("DTSTART", "DTEND", "RECURRENCE-ID"):
        moment = event_time(property_line(lines, name))
        if moment:
            days.append(moment if is_date(moment) else moment.date())
            if isinstance(moment, datetime) and moment.tzinfo:
                days.append(moment.astimezone(timezone.utc).date())
    if not days:
        raise CalendarError("The event has no usable calendar date")
    return [min(days).isoformat(), max(days).isoformat()]


def write_local(path, settings, changes):
    """Queue exact file revisions before replacing the ICS files."""
    if not changes:
        return "local"
    before = {}
    revisions = {}
    for file, lines in changes.items():
        if file.parent != path or file.is_symlink():
            raise CalendarError("The event points outside the selected calendar")
        before[file] = read_bounded(file, MAX_ICS_BYTES) if file.exists() else None
        after = encode_ics(lines) if lines is not None else None
        if before[file] != after:
            revisions[file] = after
    if not revisions:
        return "local"

    state = None
    previous = None
    if is_google(settings):
        state = load_queue()
        previous = json.loads(json.dumps(state))
        inventory = read_state(INVENTORY_FILE, {})
        slug = path.name
        remote = calendar_remote(settings)
        trusted = inventory.get(slug)
        if not trusted or trusted["remote"] != remote:
            trusted = {"remote": remote, "files": initial_inventory(path)}
            inventory[slug] = trusted
            atomic_json(INVENTORY_FILE, inventory)
        entry = state["calendars"].setdefault(slug, {"remote": remote, "changes": {}})
        if entry["remote"] != remote:
            raise CalendarError("The calendar account changed while local edits were queued")
        if entry.get("uncertain"):
            raise CalendarError("A previous upload needs review before this calendar can be edited", 75)
        for file, after in revisions.items():
            before_hash = digest(before[file])
            prior = entry["changes"].get(file.name)
            if prior is not None:
                if before_hash != prior["after"]:
                    raise CalendarError("A queued event changed outside the calendar plugin")
                original = prior["before"]
            else:
                if before_hash != trusted["files"].get(file.name):
                    raise CalendarError("The event changed outside the calendar plugin")
                original = before_hash
            if after is None and original is None:
                entry["changes"].pop(file.name, None)
                continue
            old_lines = unfold(before[file].decode()) if before[file] is not None else None
            lines = changes[file] or old_lines
            identity = event_identity(lines)
            days = date_bounds(lines)
            if old_lines:
                days.extend(date_bounds(old_lines))
            if prior:
                days.extend(prior["dates"])
            entry["changes"][file.name] = {"before": original, "after": digest(after), "dates": [min(days), max(days)],
                                           "uid": identity[0], "recurrence": identity[1],
                                           "provider_id": property_value(lines, PROVIDER_ID)}
        entry["retry_at"] = 0
        entry["failures"] = 0
        if not entry["changes"]:
            del state["calendars"][slug]
        # Until every atomic write is complete, this blocks both push and pull.
        state["preparing"] = {"slug": slug, "before": {file.name: digest(before[file]) for file in revisions},
                              "after": {file.name: digest(after) for file, after in revisions.items()},
                              "previous": previous["calendars"].get(slug)}
        save_queue(state)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup_root = STATE_DIR / "backups" / stamp / path.name
    try:
        for file in revisions:
            if before[file] is not None:
                backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
                atomic_write(backup_root / file.name, before[file])
        for file, after in revisions.items():
            if after is None:
                file.unlink()
                sync_directory(path)
            else:
                atomic_write(file, after)
    except OSError:
        for file in revisions:
            if before[file] is None:
                file.unlink(missing_ok=True)
            else:
                atomic_write(file, before[file])
        sync_directory(path)
        if state is not None:
            save_queue(previous)
        raise
    if state is None:
        return "local"
    del state["preparing"]
    save_queue(state)
    return "pending" if path.name in state["calendars"] else "local"


def recover_preparation(state, root):
    preparation = state.get("preparing")
    if not preparation:
        return
    path = calendar_directory(root, preparation["slug"])
    current = {name: file_digest(path / name) for name in preparation["after"]}
    if current == preparation["before"]:
        if preparation["previous"] is not None:
            state["calendars"][path.name] = preparation["previous"]
        else:
            state["calendars"].pop(path.name, None)
    elif current != preparation["after"]:
        raise CalendarError("An interrupted local calendar edit needs recovery from its backup", 75)
    del state["preparing"]
    save_queue(state)


def attempt_plan(entry):
    return STATE_DIR / "attempts" / entry["attempt"] / "plan.json"


def clear_attempt(entry):
    plan = attempt_plan(entry)
    plan.with_suffix(".json.receipt").unlink(missing_ok=True)
    plan.unlink(missing_ok=True)
    try:
        plan.parent.rmdir()
    except FileNotFoundError:
        pass


def recover_attempts(state, root):
    applied = False
    for slug, entry in list(state["calendars"].items()):
        if "attempt" not in entry:
            continue
        if not re.fullmatch(r"[a-f0-9]{32}", entry["attempt"]):
            raise CalendarError("The calendar attempt state is invalid")
        path = calendar_directory(root, slug)
        settings = calendar_settings(path)
        if calendar_remote(settings) != entry["remote"]:
            raise CalendarError("The pending calendar account changed")
        receipts = read_receipts(attempt_plan(entry))
        applied |= finish_attempt(state, path, entry, settings, receipts)
    return applied


def checked_remote_command(command, *args, expected=(), environment=None):
    code, output, stderr = caldir(command, *args, environment=environment)
    lines = output.splitlines()
    found = {line[2:] for line in lines if line.startswith("📅 ")}
    failed = (code != 0 or bool(stderr.strip()) or not set(expected).issubset(found)
              or any(DIAGNOSTIC.match(line) for line in lines))
    return not failed, "\n".join(filter(None, (output.strip(), stderr.strip())))


def pull(args):
    state = load_queue()
    root, _ = config()
    recover_preparation(state, root)
    recover_attempts(state, root)
    if state["calendars"]:
        raise CalendarError("Local calendar changes are waiting to be sent", 75)
    paths = [path for path in existing_calendar_paths(root) if is_google(calendar_settings(path))]
    if not paths:
        return
    prior_ids = {path.name: local_ids(path) for path in paths}
    success, _ = checked_remote_command("pull", *args, expected=[path.name for path in paths])
    for path in paths:
        refresh_inventory(path, calendar_settings(path), previous_ids=prior_ids[path.name], complete_pull=success)
    if not success:
        raise CalendarError("Google Calendar could not download every calendar change")


def verify_inventory(path, entry):
    inventory = read_state(INVENTORY_FILE, {})
    trusted = inventory.get(path.name)
    if not trusted or trusted["remote"] != entry["remote"]:
        raise CalendarError("The calendar account no longer matches its queued changes")
    expected = trusted["files"].copy()
    for name, change in entry["changes"].items():
        if change["after"] is None:
            expected.pop(name, None)
        else:
            expected[name] = change["after"]
    if expected != calendar_fingerprints(path):
        raise CalendarError("The private Caldir contains local edits outside this plugin")
    deleted = {(change["uid"], change["recurrence"]) for change in entry["changes"].values() if change["after"] is None}
    if synced_ids(path) - local_ids(path) - deleted:
        raise CalendarError("The private Caldir contains events removed outside this plugin")


def extend_date(value, delta):
    return date.fromordinal(max(date.min.toordinal(), min(date.max.toordinal(), value.toordinal() + delta)))


def push_bounds(entry):
    days = [date.fromisoformat(day) for change in entry["changes"].values() for day in change["dates"]]
    return "--from", extend_date(min(days), -2).isoformat(), "--to", extend_date(max(days), 2).isoformat()


def rebase_queue(path, entry):
    """Drop accepted writes recorded by Caldir even on a partial push."""
    calendar_events = {}
    for file in event_files(path):
        lines = read_lines(file)
        calendar_events[event_identity(lines)] = (file, lines)
    bases = {}
    for file in event_files(path / ".caldir/state/bases"):
        lines = read_lines(file)
        bases[event_identity(lines)] = lines
    remaining = {}
    accepted = False
    for name, change in entry["changes"].items():
        identity = change["uid"], change["recurrence"]
        if change["after"] is None:
            remaining[name] = change
            continue
        file, lines = calendar_events.get(identity, (None, None))
        base = bases.get(identity)
        if file and base and sync_fingerprint(lines) == sync_fingerprint(base):
            accepted = True
            continue
        # Keep the original bytes as the authorization. A rewritten local
        # file with no matching Caldir base must not be adopted for retry.
        remaining[name] = change
    entry["changes"] = remaining
    return accepted


def retry_later(entry):
    entry["failures"] = min(entry.get("failures", 0) + 1, 5)
    entry["retry_at"] = int(time.time()) + min(300, 30 * 2 ** (entry["failures"] - 1))


def read_receipts(plan):
    try:
        data = read_bounded(plan.with_suffix(plan.suffix + ".receipt"), MAX_CACHE_BYTES)
        return [json.loads(line) for line in data.splitlines()]
    except FileNotFoundError:
        return []


def receipt_key(value):
    return value["action"], value["uid"], value["recurrence"]


def make_plan(entry):
    allow = []
    for change in entry["changes"].values():
        if change["after"] is None:
            actions = ("delete_event",)
        elif change["before"] is None:
            actions = ("create_event", "update_event") if change["recurrence"] else ("create_event",)
        else:
            actions = ("update_event",)
        allow.extend({"uid": change["uid"], "recurrence": change["recurrence"], "action": action} for action in actions)
    plan = attempt_plan(entry)
    plan.parent.mkdir(mode=0o700, parents=True)
    remote = {key: entry["remote"][key] for key in ("google_account", "google_calendar_id")}
    atomic_json(plan, {**remote, "allow": allow})
    return plan


def gated_push(path, entry, plan):
    environment = {**os.environ, "OMARCHY_CALENDAR_PUSH_PLAN": str(plan)}
    try:
        return checked_remote_command("push", "--calendar", path.name, *push_bounds(entry),
                                      expected=[path.name], environment=environment)
    except CaldirTimeout:
        return False, ""


def finish_attempt(state, path, entry, settings, receipts):
    started = {receipt_key(item) for item in receipts if item["status"] == "started"}
    accepted = {receipt_key(item) for item in receipts if item["status"] == "success"}
    rejected = {receipt_key(item) for item in receipts if item["status"] == "refused"}
    inconclusive = started - rejected
    applied = rebase_queue(path, entry)
    if not any(change["before"] is None and change["after"] is not None and not change["provider_id"]
               and ("create_event", change["uid"], change["recurrence"]) in inconclusive
               for change in entry["changes"].values()):
        entry.pop("uncertain", None)
    deleted = []
    for name, change in list(entry["changes"].items()):
        identity = change["uid"], change["recurrence"]
        if change["after"] is None and ("delete_event", *identity) in accepted:
            deleted.append(identity)
            del entry["changes"][name]
    refresh_inventory(path, settings, deleted=deleted)
    finished = {"attempt": entry.pop("attempt")}
    if not entry["changes"]:
        del state["calendars"][path.name]
    else:
        retry_later(entry)
    save_queue(state)
    clear_attempt(finished)
    return applied or bool(deleted)


def push(*, automatic):
    state = load_queue()
    if not state["calendars"] and not state.get("preparing"):
        return "idle", ""
    root, _ = config()
    recover_preparation(state, root)
    completed = recover_attempts(state, root)
    error = None
    output = []
    for slug, entry in list(state["calendars"].items()):
        if automatic and entry.get("retry_at", 0) > time.time():
            continue
        path = calendar_directory(root, slug)
        settings = calendar_settings(path)
        if calendar_remote(settings) != entry["remote"] or settings.get("read_only") is not False:
            raise CalendarError("The queued Google calendar is unavailable or read-only")
        if entry.get("uncertain"):
            if rebase_queue(path, entry) and not entry["changes"]:
                refresh_inventory(path, settings)
                del state["calendars"][slug]
                save_queue(state)
                completed = True
                continue
            error = "A previous Google upload needs review before it can be retried safely"
            continue
        verify_inventory(path, entry)
        has_create = any(change["before"] is None and change["after"] is not None and not change["provider_id"]
                         for change in entry["changes"].values())
        if has_create:
            # Leave a durable retry barrier if the client dies during insert.
            entry["uncertain"] = True
        entry["attempt"] = uuid4().hex
        entry["retry_at"] = int(time.time()) + 100
        plan = make_plan(entry)
        save_queue(state)
        success, detail = gated_push(path, entry, plan)
        output.append(detail)
        completed |= finish_attempt(state, path, entry, settings, read_receipts(plan))
        if not success or entry["changes"]:
            error = "Google Calendar did not accept every queued change"
    if error:
        raise CalendarError(error)
    if state["calendars"]:
        return "pending", ""
    return ("synced" if completed else "idle"), "\n".join(output)
