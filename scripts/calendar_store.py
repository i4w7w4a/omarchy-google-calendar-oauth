"""Private state, iCalendar fields and the common Caldir process boundary."""

from __future__ import annotations

import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import tomllib
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

SCRIPT_DIR = Path(__file__).resolve().parent
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "omarchy-calendar"
CACHE_FILE = STATE_DIR / "cache.json"
PENDING_FILE = STATE_DIR / "pending.json"
MAX_CACHE_BYTES = 16 * 1024 * 1024
MAX_ICS_BYTES = 256 * 1024
MAX_EVENTS = 10000
DEFAULT_DURATION = 60
MAX_DURATION = 10080
MAX_REMINDER = 40320
SLUG = re.compile(r"[A-Za-z0-9._-]{1,160}")
CLOCK = re.compile(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]")
ICAL_DATE = re.compile(r"[0-9]{8}")
ICAL_TIME = re.compile(r"[0-9]{8}T[0-9]{6}Z?")
DEFAULT_REMINDER = "X-GOOGLE-DEFAULT-REMINDERS"
PROVIDER_ID = "X-GOOGLE-EVENT-ID"
RRULE = re.compile(r"FREQ=(?:DAILY|WEEKLY|MONTHLY|YEARLY)(?:;COUNT=(?:[2-9]|[1-9][0-9]{1,2}))?")
DURATION = re.compile(r"P(?:(?P<weeks>[0-9]+)W|(?:(?P<days>[0-9]+)D)?(?:T(?:(?P<hours>[0-9]+)H)?(?:(?P<minutes>[0-9]+)M)?(?:(?P<seconds>[0-9]+)S)?)?)")
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
lock_fd = None


class CalendarError(Exception):
    def __init__(self, message, code=1, reason=None):
        super().__init__(message)
        self.code = code
        self.reason = reason


class CaldirTimeout(CalendarError):
    pass


@contextmanager
def calendar_lock(*, wait=True):
    """Serialize Caldir filesystem operations from every screen."""
    global lock_fd
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(STATE_DIR / "calendar.lock", os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as lock:
        operation = fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB
        try:
            fcntl.flock(lock, operation)
        except BlockingIOError as error:
            raise CalendarError("The calendar is busy", 75, "busy") from error
        lock_fd = lock.fileno()
        try:
            yield
        finally:
            lock_fd = None


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write(path, payload):
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def atomic_json(path, value):
    atomic_write(path, (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode())


def read_bounded(path, limit):
    with path.open("rb") as stream:
        contents = stream.read(limit + 1)
    if len(contents) > limit:
        raise CalendarError("A calendar data file is too large")
    return contents


def json_output(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def json_input():
    try:
        contents = sys.stdin.buffer.read(65537)
        if len(contents) <= 65536:
            value = json.loads(contents)
            if isinstance(value, dict):
                return value
    except (UnicodeError, ValueError, RecursionError):
        pass
    raise CalendarError("Expected a calendar request JSON object", 64)


def text_value(request, key, default="", limit=1024, *, multiline=False):
    value = request.get(key, default)
    if not isinstance(value, str) or len(value) > limit or any(
        ord(character) < 32 and (not multiline or character not in "\t\r\n") for character in value
    ):
        raise CalendarError(f"Invalid {key} in the calendar request", 64)
    return value


def validate_title(request):
    title = text_value(request, "title").strip()
    if not title:
        raise CalendarError("Event title cannot be empty", 64)
    return title


def bounded_integer(value, lower, upper, label):
    if type(value) is not int or not lower <= value <= upper:
        raise CalendarError(f"{label} must be between {lower} and {upper}", 64)
    return value


def duration_request(request):
    value = request.get("duration_minutes")
    return None if value is None else bounded_integer(value, 1, MAX_DURATION, "Duration")


def reminder_request(request, default):
    value = request.get("reminder", {"mode": default})
    if not isinstance(value, dict) or value.get("mode") not in ("keep", "default", "none", "custom"):
        raise CalendarError("Invalid reminder setting", 64)
    if value["mode"] == "custom":
        return {"mode": "custom", "minutes": bounded_integer(value.get("minutes"), 1, MAX_REMINDER, "Reminder")}
    return {"mode": value["mode"]}


def iso_date(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value):
        raise CalendarError("Date must be YYYY-MM-DD", 64)
    try:
        return date.fromisoformat(value)
    except ValueError as error:
        raise CalendarError("Invalid calendar date", 64) from error


def caldir(*args, timeout=95, limit=MAX_CACHE_BYTES, environment=None):
    binary = SCRIPT_DIR / "calendar-caldir"
    if not os.access(binary, os.X_OK):
        raise CalendarError("Caldir is not installed", 127)
    pass_fds = () if lock_fd is None else (lock_fd,)
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        with subprocess.Popen([str(binary), *args], stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                              start_new_session=True, env=environment, pass_fds=pass_fds) as process:
            def cancel(_signal, _frame):
                raise InterruptedError("The calendar operation was cancelled")

            previous_handlers = {number: signal.signal(number, cancel) for number in (signal.SIGINT, signal.SIGTERM)}
            try:
                process.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, InterruptedError) as error:
                for number in previous_handlers:
                    signal.signal(number, signal.SIG_IGN)
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                except ProcessLookupError:
                    pass
                raise CaldirTimeout("The calendar request timed out") from error
            finally:
                for number, handler in previous_handlers.items():
                    signal.signal(number, handler)
        stdout.seek(0)
        stderr.seek(0)
        output = stdout.read(limit + 1)
        errors = stderr.read(65537)
    if len(output) > limit or len(errors) > 65536:
        raise CalendarError("Caldir returned too much data")
    return process.returncode, ANSI.sub("", output.decode("utf-8", "replace")), ANSI.sub("", errors.decode("utf-8", "replace"))


def config():
    code, output, _ = caldir("config", "--json", timeout=8)
    if code:
        raise CalendarError("Could not read the private Caldir profile", 127)
    try:
        value = json.loads(output)["config"]
        root = Path(value["calendar_dir"]).expanduser().resolve()
        return root, value.get("default_calendar")
    except (TypeError, KeyError, ValueError, AttributeError) as error:
        raise CalendarError("Could not read the private Caldir profile") from error


def calendar_directory(root, slug):
    if not isinstance(slug, str) or not SLUG.fullmatch(slug) or slug in {".", ".."}:
        raise CalendarError("Invalid calendar name", 64)
    path = root / slug
    if path.is_symlink() or not path.is_dir():
        raise CalendarError("The selected calendar does not exist")
    return path


def calendar_settings(path):
    try:
        value = tomllib.loads(read_bounded(path / ".caldir/config.toml", 65536).decode())
    except (OSError, ValueError) as error:
        raise CalendarError("Could not read the selected calendar configuration") from error
    return value


def is_google(settings):
    return settings.get("remote", {}).get("provider") == "google"


def require_writable(path):
    settings = calendar_settings(path)
    if settings.get("read_only") is not False:
        raise CalendarError("This calendar is read-only")
    return settings


def unfold(contents):
    lines = []
    for line in contents.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line.startswith((" ", "\t")) and lines:
            lines[-1] += line[1:]
        elif line:
            lines.append(line)
    return lines


def read_lines(path):
    return unfold(read_bounded(path, MAX_ICS_BYTES).decode())


def fold_line(line):
    result = []
    current = ""
    width = 0
    for character in line:
        size = len(character.encode("utf-8"))
        if width + size > 75:
            result.append(current)
            current = " "
            width = 1
        current += character
        width += size
    result.append(current)
    return "\r\n".join(result)


def encode_ics(lines):
    payload = ("\r\n".join(fold_line(line) for line in lines) + "\r\n").encode()
    if len(payload) > MAX_ICS_BYTES:
        raise CalendarError("An event exceeds the local calendar size limit")
    return payload


def split_property(line):
    quoted = False
    for index, character in enumerate(line):
        if character == '"':
            quoted = not quoted
        elif character == ":" and not quoted:
            return line[:index], line[index + 1:]
    return line, ""


def property_name(line):
    return line.split(";", 1)[0].split(":", 1)[0].upper()


def parameter(line, name):
    head, _ = split_property(line)
    match = re.search(r'(?:^|;)' + name + r'=(?:"([^"]*)"|([^;]*))', head, re.IGNORECASE)
    return (match[1] or match[2]) if match else None


def event_bounds(lines):
    starts = [index for index, line in enumerate(lines) if line.upper() == "BEGIN:VEVENT"]
    ends = [index for index, line in enumerate(lines) if line.upper() == "END:VEVENT"]
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise CalendarError("Expected one event in the local ICS file")
    return starts[0], ends[0]


def property_indexes(lines):
    start, end = event_bounds(lines)
    depth = 0
    for index in range(start + 1, end):
        name = property_name(lines[index])
        if name == "BEGIN":
            depth += 1
        elif name == "END":
            depth -= 1
        elif depth == 0:
            yield index


def property_line(lines, name):
    return next((lines[i] for i in property_indexes(lines) if property_name(lines[i]) == name), None)


def property_value(lines, name):
    line = property_line(lines, name)
    return split_property(line)[1] if line else None


def set_property(lines, name, value, params=""):
    indexes = [i for i in property_indexes(lines) if property_name(lines[i]) == name]
    if value is None:
        for index in reversed(indexes):
            del lines[index]
    elif indexes:
        lines[indexes[0]] = name + params + ":" + value
        for index in reversed(indexes[1:]):
            del lines[index]
    else:
        _, end = event_bounds(lines)
        lines.insert(end, name + params + ":" + value)


def escape_text(value):
    value = value.replace("\r\n", "\n").replace("\r", "\n")
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace(";", "\\;").replace(",", "\\,")


def unescape_text(value):
    return re.sub(r"\\([nN;,\\])", lambda match: "\n" if match[1].lower() == "n" else match[1], value)


def revision(lines):
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    try:
        sequence = int(property_value(lines, "SEQUENCE") or "0") + 1
    except ValueError:
        sequence = 1
    set_property(lines, "DTSTAMP", stamp)
    set_property(lines, "LAST-MODIFIED", stamp)
    set_property(lines, "SEQUENCE", str(sequence))


def duration_value(value):
    if not value or len(value) > 40:
        return None
    match = DURATION.fullmatch(value)
    if not match or not any(match.groups()):
        return None
    try:
        return timedelta(**{unit: int(number or 0) for unit, number in match.groupdict().items()})
    except OverflowError:
        return None


def local_zone():
    tzid = os.environ.get("TZ", "").lstrip(":")
    if not tzid:
        name = str(Path("/etc/localtime").resolve())
        tzid = name.partition("/zoneinfo/")[2]
    if tzid:
        try:
            return ZoneInfo(tzid)
        except (ValueError, ZoneInfoNotFoundError):
            pass
    with Path("/etc/localtime").open("rb") as stream:
        return ZoneInfo.from_file(stream)


def localize(moment, zone, *, strict=False):
    candidate = moment.replace(tzinfo=zone)
    actual = candidate.astimezone(timezone.utc).astimezone(zone)
    if strict and actual.replace(tzinfo=None) != moment:
        raise CalendarError("The selected time does not exist in the local time zone", 64)
    return actual


def ambiguous_time(moment):
    if not moment.tzinfo:
        return False
    before = moment.replace(fold=0)
    after = moment.replace(fold=1)
    return (before.utcoffset() != after.utcoffset()
            and before.astimezone(timezone.utc).astimezone(moment.tzinfo).replace(tzinfo=None)
            == after.astimezone(timezone.utc).astimezone(moment.tzinfo).replace(tzinfo=None))


def event_time(line):
    if not line:
        return None
    _, value = split_property(line)
    try:
        if ICAL_DATE.fullmatch(value):
            return datetime.strptime(value, "%Y%m%d").date()
        if not ICAL_TIME.fullmatch(value):
            raise ValueError("invalid ICS time")
        result = datetime.strptime(value.rstrip("Z"), "%Y%m%dT%H%M%S")
        if value.endswith("Z"):
            return result.replace(tzinfo=timezone.utc)
        tzid = parameter(line, "TZID")
        if tzid:
            try:
                return localize(result, ZoneInfo(tzid))
            except (ValueError, ZoneInfoNotFoundError):
                return result
        return result
    except ValueError as error:
        raise CalendarError("This event uses an invalid calendar date") from error


def is_date(value):
    return isinstance(value, date) and not isinstance(value, datetime)


def elapsed(start, end):
    if not start or not end or is_date(start) != is_date(end):
        return None
    if not is_date(start):
        start, end = (absolute(start), absolute(end))
    return end - start


def absolute(moment):
    return (moment if moment.tzinfo else localize(moment, local_zone())).astimezone(timezone.utc)


def event_duration(lines):
    start = event_time(property_line(lines, "DTSTART"))
    end = event_time(property_line(lines, "DTEND"))
    return elapsed(start, end) or duration_value(property_value(lines, "DURATION"))


def duration_minutes(duration):
    if duration and duration > timedelta(0):
        return max(1, round(duration.total_seconds() / 60))
    return None


def add_elapsed(start, duration):
    if start.tzinfo is None:
        return (absolute(start) + duration).astimezone(local_zone()).replace(tzinfo=None)
    return (start.astimezone(timezone.utc) + duration).astimezone(start.tzinfo)


def time_value(moment, *, provider_safe=False):
    if is_date(moment):
        return moment.strftime("%Y%m%d"), ";VALUE=DATE"
    if moment.tzinfo is timezone.utc:
        return moment.strftime("%Y%m%dT%H%M%SZ"), ""
    tzid = getattr(moment.tzinfo, "key", None)
    if tzid and not moment.fold and not (provider_safe and ambiguous_time(moment)):
        return moment.strftime("%Y%m%dT%H%M%S"), ";TZID=" + tzid
    if moment.tzinfo is not None:
        return time_value(moment.astimezone(timezone.utc))
    return moment.strftime("%Y%m%dT%H%M%S"), ""


def set_event_times(lines, start, end):
    if property_value(lines, "RRULE") and isinstance(start, datetime) and ambiguous_time(start):
        raise CalendarError("Choose a time that occurs only once on the first day of this series", 64)
    set_property(lines, "DTSTART", *time_value(start, provider_safe=True))
    set_property(lines, "DTEND", *time_value(end, provider_safe=True))
    set_property(lines, "DURATION", None)


def alarm_ranges(lines):
    start, end = event_bounds(lines)
    index = start + 1
    while index < end:
        if lines[index].upper() != "BEGIN:VALARM":
            index += 1
            continue
        stop = next((i for i in range(index + 1, end) if lines[i].upper() == "END:VALARM"), None)
        if stop is None:
            raise CalendarError("The event has an incomplete reminder")
        yield index, stop + 1
        index = stop + 1


def set_reminder(lines, reminder, google):
    mode = reminder["mode"]
    if mode == "keep":
        return
    for start, end in reversed(list(alarm_ranges(lines))):
        del lines[start:end]
    set_property(lines, DEFAULT_REMINDER, "TRUE" if mode == "default" and google else None)
    if mode == "custom":
        _, end = event_bounds(lines)
        minutes = reminder["minutes"]
        lines[end:end] = ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder",
                          f"TRIGGER;RELATED=START:-PT{minutes}M", "END:VALARM"]


def reminder_metadata(lines):
    ranges = list(alarm_ranges(lines))
    offsets = []
    for start, end in ranges:
        properties = lines[start + 1:end - 1]
        action = next((split_property(line)[1] for line in properties if property_name(line) == "ACTION"), "DISPLAY")
        trigger = next((line for line in properties if property_name(line) == "TRIGGER"), "")
        _, value = split_property(trigger)
        if (action.upper() != "DISPLAY" or (parameter(trigger, "RELATED") or "START").upper() != "START"
                or (parameter(trigger, "VALUE") or "DURATION").upper() != "DURATION"
                or any(property_name(line) in {"REPEAT", "DURATION"} for line in properties)):
            continue
        duration = duration_value(value.removeprefix("-"))
        if duration is not None and (value.startswith("-") or not duration):
            minutes, seconds = divmod(int(duration.total_seconds()), 60)
            if not seconds and 0 <= minutes <= MAX_REMINDER:
                offsets.append(minutes)
    if ranges:
        reminder = {"mode": "custom", "minutes": offsets[0]} if len(ranges) == len(offsets) == 1 and offsets[0] else {"mode": "keep"}
    else:
        default = (property_value(lines, DEFAULT_REMINDER) or "").upper() == "TRUE"
        reminder = {"mode": "default" if default else "none"}
    return reminder, sorted(set(offsets), reverse=True)[:5]


def require_google_reminders(lines):
    """The pinned provider only round-trips positive start-relative DISPLAY alarms."""
    ranges = list(alarm_ranges(lines))
    _, offsets = reminder_metadata(lines)
    marked_default = (property_value(lines, DEFAULT_REMINDER) or "").upper() == "TRUE"
    if len(ranges) != len(offsets) or 0 in offsets or (ranges and marked_default):
        raise CalendarError("Google cannot preserve these reminders. Choose a new reminder or edit this event in Google Calendar.")


def require_google_roundtrip(lines):
    require_google_reminders(lines)
    if any(property_line(lines, name) for name in ("RDATE", "EXRULE", "DURATION", "ATTACH")):
        raise CalendarError("This event has calendar fields the local Google provider cannot preserve")
    for name in ("DTSTART", "DTEND"):
        line = property_line(lines, name)
        if line is None:
            continue
        moment = event_time(line)
        if is_date(moment):
            continue
        original = split_property(line)[1]
        suffix = "Z" if original.endswith("Z") else ""
        if not moment.tzinfo or ambiguous_time(moment) or original != moment.strftime("%Y%m%dT%H%M%S") + suffix:
            raise CalendarError("Google cannot preserve this event’s local time. Choose a new start time in Google Calendar.")


def recurrence_id(line):
    if not line:
        return ""
    _, value = split_property(line)
    tzid = parameter(line, "TZID")
    return f"TZID={tzid}:{value}" if tzid else value


def instance_identity(uid, rid):
    if not rid:
        return uid, ""
    params, separator, value = rid.rpartition(":")
    if separator and not params.startswith("TZID="):
        raise CalendarError("Invalid recurrence identifier")
    moment = event_time("RECURRENCE-ID;" + params + ":" + value if separator else "RECURRENCE-ID:" + value)
    if isinstance(moment, datetime) and moment.tzinfo:
        return uid, absolute(moment).isoformat()
    return uid, moment.isoformat()


def event_identity(lines):
    uid = unescape_text(property_value(lines, "UID") or "")
    if not uid:
        raise CalendarError("A local event has no UID")
    return instance_identity(uid, recurrence_id(property_line(lines, "RECURRENCE-ID")))


def event_files(path):
    return (entry for entry in sorted(path.glob("*.ics")) if entry.is_file() and not entry.is_symlink())


def handle_error(error, structured=False, sync=None):
    if isinstance(error, CalendarError):
        message, code = str(error), error.code
    else:
        message, code = "Could not read or save private calendar data", 1
    if structured:
        value = {"ok": False, "error": message}
        if isinstance(error, CalendarError) and error.reason:
            value["reason"] = error.reason
        if sync is not None:
            value["sync"] = sync
        json_output(value)
    else:
        print(message, file=sys.stderr)
    return code
