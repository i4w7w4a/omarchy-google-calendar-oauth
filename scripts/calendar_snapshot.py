"""Build the clock's bounded JSON snapshot from the private local Caldir."""

from __future__ import annotations

import json
import re
import subprocess
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from calendar_store import (
    CACHE_FILE, CalendarError, MAX_CACHE_BYTES, MAX_EVENTS, MAX_REMINDER, SLUG,
    add_elapsed, atomic_json, caldir, calendar_settings, config, duration_minutes, elapsed, event_duration,
    event_files, event_identity, event_time, instance_identity, iso_date, local_zone, property_line, property_value, read_bounded,
    read_lines, reminder_metadata, unescape_text,
)
from calendar_sync import content_fingerprint, existing_calendar_paths


def google_defaults(path):
    try:
        value = json.loads(read_bounded(path / ".caldir/google-reminders.json", 4096))
    except (OSError, ValueError, CalendarError):
        return None
    if isinstance(value, dict):
        value = value.get("minutes", [])
    if not isinstance(value, list):
        return None
    return sorted({item for item in value if type(item) is int and 0 <= item <= MAX_REMINDER}, reverse=True)[:5]


def bounded_text(value, limit):
    return value[:limit].replace("\x00", "") if isinstance(value, str) else ""


def event_metadata(lines, defaults):
    start = event_time(property_line(lines, "DTSTART"))
    all_day = not isinstance(start, datetime)
    reminder, offsets = reminder_metadata(lines)
    duration = event_duration(lines)
    if start and not all_day and start.tzinfo is None:
        start = start.replace(tzinfo=local_zone())
    return {
        "revision": content_fingerprint(lines),
        "start": start.isoformat() if start else None,
        "all_day": all_day,
        "duration_minutes": None if all_day else duration_minutes(duration),
        "duration": duration,
        "reminder": reminder,
        "reminder_offsets": defaults if reminder["mode"] == "default" else offsets,
        "recurrence_rule": bounded_text(property_value(lines, "RRULE"), 4096) or None,
        "provider_event_type": bounded_text(property_value(lines, "X-GOOGLE-EVENT-TYPE"), 64) or None,
        "conference_url": bounded_text(property_value(lines, "X-GOOGLE-CONFERENCE"), 4096) or None,
        "title": bounded_text(unescape_text(property_value(lines, "SUMMARY") or ""), 4096),
        "description": bounded_text(unescape_text(property_value(lines, "DESCRIPTION") or ""), 20000),
    }


def all_metadata(root):
    calendars = {}
    events = {}
    for path in existing_calendar_paths(root):
        if not SLUG.fullmatch(path.name):
            continue
        settings = calendar_settings(path)
        color = settings.get("color")
        calendars[path.name] = {
            "calendar_color": color if isinstance(color, str) and re.fullmatch(r"#[0-9A-Fa-f]{6}", color) else None,
            "calendar_read_only": settings.get("read_only") is not False,
        }
        defaults = google_defaults(path)
        for file in event_files(path):
            try:
                lines = read_lines(file)
                uid, rid = event_identity(lines)
                events[path.name, uid, rid] = event_metadata(lines, defaults)
            except (CalendarError, OSError, ValueError):
                continue
    return calendars, events


def valid_datetime(value):
    if not isinstance(value, str) or len(value) > 64:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")) if "T" in value else date.fromisoformat(value)
    except ValueError:
        return None


def snapshot(start, end):
    root, _ = config()
    code, output, _ = caldir("--json", "events", "--from", start, "--to", end, timeout=12)
    if code:
        if not any(existing_calendar_paths(root)):
            return {"ok": True, "events": []}
        raise CalendarError("Could not read local calendar events")
    try:
        source = json.loads(output)
    except (ValueError, RecursionError) as error:
        raise CalendarError("Caldir returned invalid local events") from error
    if not isinstance(source, list) or len(source) > MAX_EVENTS:
        raise CalendarError("The calendar window contains too many events")
    calendars, events = all_metadata(root)
    result = []
    for entry in source:
        if not isinstance(entry, dict):
            continue
        calendar, uid, instance_id = (entry.get(key) for key in ("calendar", "uid", "instance_id"))
        if (not isinstance(calendar, str) or not SLUG.fullmatch(calendar) or not isinstance(uid, str)
                or not 0 < len(uid) <= 1024 or not isinstance(instance_id, str) or not 0 < len(instance_id) <= 2048
                or any(ord(character) < 32 for character in uid + instance_id)):
            continue
        starts_at = valid_datetime(entry.get("start"))
        if not starts_at:
            continue
        ends_at = valid_datetime(entry.get("end"))
        rid = entry.get("recurrence_id")
        try:
            _, normalized = instance_identity(uid, rid if isinstance(rid, str) else "")
        except (CalendarError, ValueError):
            continue
        master = events.get((calendar, uid, ""), {})
        own = events.get((calendar, uid, normalized))
        exact = own if own is not None else master
        title = bounded_text(entry.get("title") or entry.get("summary"), 4096)
        description = bounded_text(entry.get("description"), 20000)
        provider_type = exact.get("provider_event_type") or master.get("provider_event_type")
        reminder = exact.get("reminder", {"mode": "keep"})
        all_day = entry.get("all_day") is True
        duration = exact.get("duration_minutes") if not all_day else None
        if duration is None and not all_day:
            duration = duration_minutes(elapsed(starts_at, ends_at))
        end_value = entry.get("end") if ends_at else None
        # Caldir expands zoned occurrences using wall-clock addition and can
        # omit DURATION-only ends. Resolve both from the actual local file.
        if not all_day and isinstance(starts_at, datetime) and exact.get("duration"):
            tzid = entry.get("tzid")
            if isinstance(tzid, str):
                try:
                    starts_at = starts_at.astimezone(ZoneInfo(tzid))
                except (ValueError, ZoneInfoNotFoundError):
                    pass
            end_value = add_elapsed(starts_at, exact["duration"]).isoformat()
        item = {
            "calendar": calendar, "uid": uid, "instance_id": instance_id,
            "title": title, "summary": title, "description": description,
            "start": entry["start"], "end": end_value,
            "all_day": all_day, "recurring": entry.get("recurring") is True,
            "duration_minutes": duration,
            "reminder": reminder, "reminder_offsets": exact.get("reminder_offsets", []),
            "revision": exact.get("revision"), "series_revision": master.get("revision"),
            "series_start": master.get("start"), "series_all_day": master.get("all_day"),
            "series_duration_minutes": master.get("duration_minutes"), "series_reminder": master.get("reminder"),
            "series_title": master.get("title"), "series_description": master.get("description"),
            "location": bounded_text(entry.get("location"), 4096), "url": bounded_text(entry.get("url"), 4096),
            "recurrence_rule": master.get("recurrence_rule"), "provider_event_type": provider_type,
            "conference_url": exact.get("conference_url") or master.get("conference_url"),
            "event_title_only": provider_type == "birthday",
            "event_read_only": provider_type not in (None, "default", "birthday") or len(title) > 1024 or len(description) > 10000,
            **calendars.get(calendar, {"calendar_color": None, "calendar_read_only": True}),
        }
        result.append(item)
    return {"ok": True, "events": result}


def read_cache():
    try:
        value = json.loads(read_bounded(CACHE_FILE, MAX_CACHE_BYTES))
    except FileNotFoundError:
        return {"ok": False, "error": "Calendar cache is not ready yet"}
    except (CalendarError, OSError, ValueError, RecursionError):
        return {"ok": False, "error": "Calendar cache is invalid"}
    if not isinstance(value, dict) or value.get("ok") is not True or not isinstance(value.get("events"), list):
        return {"ok": False, "error": "Calendar cache is invalid"}
    return value


def cache_range(requested=()):
    if len(requested) == 2:
        start, end = map(iso_date, requested)
        if start > end:
            raise CalendarError("Calendar range starts after it ends", 64)
    elif not requested:
        today = date.today()
        end_month = today.month + 6
        next_year, next_month = divmod(end_month, 12)
        future_end = date(today.year + next_year, next_month + 1, 1) - timedelta(days=1)
        start, end = date(today.year, 1, 1), max(date(today.year, 12, 31), future_end)
    else:
        raise CalendarError("Expected two calendar range dates", 64)
    previous = read_cache()
    try:
        start = min(start, iso_date(previous["range_start"]))
        end = max(end, iso_date(previous["range_end"]))
    except (CalendarError, KeyError):
        pass
    return start.isoformat(), end.isoformat()


def refresh_cache(requested=()):
    start, end = cache_range(requested)
    value = snapshot(start, end)
    value.update(generated_at=datetime.now().astimezone().isoformat(), range_start=start, range_end=end)
    if len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()) + 1 > MAX_CACHE_BYTES:
        raise CalendarError("The calendar snapshot is too large")
    atomic_json(CACHE_FILE, value)
    # The watcher reloads existing cache files. This also wakes the initial
    # shell session when the first cache is created.
    try:
        subprocess.run(["omarchy-shell", "re_pick.google-calendar-clock", "refreshCalendar"],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return f"Cached {len(value['events'])} events ({start} through {end})"


def refresh_after_local_change(result, bounds):
    try:
        start, end = cache_range()
        for first, last in bounds:
            start, end = min(start, first), max(end, last)
        refresh_cache((start, end))
    except (CalendarError, OSError, ValueError, OverflowError):
        # The durable mutation has already succeeded. Reporting a failed
        # save would invite the user to create or apply it a second time.
        result["cache_refreshed"] = False
