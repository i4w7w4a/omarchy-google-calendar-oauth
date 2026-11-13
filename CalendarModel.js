// The clock talks to Caldir through a small local command rather than parsing
// ICS itself. Caldir already handles recurrence, time zones, and provider IDs.

function parseBridgeOutput(text) {
  try {
    var payload = String(text || "")
    if (payload.length > 16 * 1024 * 1024) throw new Error("Calendar cache exceeds its size limit")
    var result = JSON.parse(payload)
    if (result && result.ok === true && Array.isArray(result.events) && result.events.length <= 10000) {
      var start = /^\d{4}-\d{2}-\d{2}$/.test(String(result.range_start || "")) ? result.range_start : ""
      var end = /^\d{4}-\d{2}-\d{2}$/.test(String(result.range_end || "")) ? result.range_end : ""
      var events = result.events.filter(function(event) {
        return event && typeof event === "object" && isFinite(eventStartTime(event))
      })
      return { events: events, rangeStart: start, rangeEnd: end, error: "" }
    }
    return { events: [], rangeStart: "", rangeEnd: "", error: boundedText(result && result.error, 1024) || "Calendar data is unavailable" }
  } catch (error) {
    return { events: [], rangeStart: "", rangeEnd: "", error: "Calendar data is unavailable" }
  }
}

function parseSyncResult(text) {
  try {
    var result = JSON.parse(String(text || ""))
    if (result && (result.ok === false || (result.ok === true && typeof result.sync === "string"))) return result
  } catch (error) {}
  return null
}

function parsePendingState(text) {
  try {
    var data = JSON.parse(String(text || ""))
    var count = data.pending_count
    if (typeof count === "number" && isFinite(count) && Math.floor(count) === count && count >= 0 && count <= 2147483647) {
      return { count: count, retryable: data.auto_retry !== false,
        retryAt: typeof data.retry_at === "number" && isFinite(data.retry_at) ? data.retry_at * 1000 : 0 }
    }
  } catch (error) {}
  return null
}

var DURATION_PRESETS = [15, 30, 60, 90, 120]
var REMINDER_PRESETS = [5, 10, 15, 30, 60, 1440]
var MAX_DURATION_MINUTES = 10080
var MAX_REMINDER_MINUTES = 40320

function parseMinutes(value, min, max) {
  if ((typeof value !== "string" && typeof value !== "number") || !/^\d+$/.test(String(value).trim()))
    return null
  var minutes = Number(value)
  return minutes >= min && minutes <= max ? minutes : null
}

function minuteChoice(minutes, presets) {
  return presets.indexOf(minutes) >= 0 ? String(minutes) : "custom"
}

function eventDurationMinutes(event, series) {
  if (!event) return 60
  if (series && event.series_duration_minutes !== undefined)
    return parseMinutes(event.series_duration_minutes, 1, MAX_DURATION_MINUTES)
  if (event.duration_minutes !== undefined)
    return parseMinutes(event.duration_minutes, 1, MAX_DURATION_MINUTES)
  if (event.all_day) return null
  var elapsedMinutes = (new Date(event.end).getTime() - eventStartTime(event)) / 60000
  return parseMinutes(elapsedMinutes, 1, MAX_DURATION_MINUTES)
}

function editableReminder(event, series) {
  if (!event) return { mode: "default" }
  var reminder = series ? event.series_reminder || event.reminder : event.reminder
  if (reminder && (reminder.mode === "default" || reminder.mode === "none")) return { mode: reminder.mode }
  if (reminder && reminder.mode === "custom") {
    var minutes = parseMinutes(reminder.minutes, 1, MAX_REMINDER_MINUTES)
    if (minutes !== null) return { mode: "custom", minutes: minutes }
  }
  return { mode: "keep" }
}

function eventEditorText(event, scope) {
  if (!event) return { title: "", description: "" }
  var series = event.recurring && scope === "series"
  return {
    title: series && typeof event.series_title === "string" ? event.series_title : String(event.title || ""),
    description: series && typeof event.series_description === "string" ? event.series_description : String(event.description || "")
  }
}

function rebaseEditorText(current, previous, next) {
  return {
    title: current.title === previous.title ? next.title : current.title,
    description: current.description === previous.description ? next.description : current.description
  }
}

function eventStartTime(event) {
  var start = event && event.start
  if (typeof start !== "string" || start.length > 64
      || !/^\d{4}-\d{2}-\d{2}(?:T\d\d:\d\d(?::\d\d(?:\.\d+)?)?(?:Z|[+-]\d\d:\d\d)?)?$/.test(start)) return NaN
  if (event.all_day && /^\d{4}-\d{2}-\d{2}$/.test(start)) start += "T00:00:00"
  return new Date(start).getTime()
}

function eventReminderOffsets(event) {
  var reminder = event.reminder
  if (reminder && reminder.mode === "none") return []
  if (reminder && reminder.mode === "custom") {
    var minutes = parseMinutes(reminder.minutes, 0, MAX_REMINDER_MINUTES)
    if (minutes !== null) return [minutes]
  }
  if (Array.isArray(event.reminder_offsets)) {
    var offsets = []
    for (var i = 0; i < event.reminder_offsets.length && i < 5; i++) {
      var offset = parseMinutes(event.reminder_offsets[i], 0, MAX_REMINDER_MINUTES)
      if (offset !== null && offsets.indexOf(offset) === -1) offsets.push(offset)
    }
    return offsets
  }
  return !event.all_day && (!reminder || reminder.mode === "default") ? [5, 0] : []
}

function dueReminderOffsets(event, now) {
  var start = eventStartTime(event)
  if (!isFinite(start)) return []
  var offsets = eventReminderOffsets(event)
  var minute = Math.floor(now / 60000)
  return offsets.filter(function(offset) {
    return Math.floor(start / 60000) - offset === minute
  })
}

function boundedText(value, maxLength) {
  return typeof value === "string" ? value.slice(0, maxLength) : ""
}

// Tooltips and notification bodies can pass through a styled-text renderer.
// Neutralize markup delimiters and character references before handing off.
function textForMarkupSink(value, maxLength) {
  return boundedText(value, maxLength).replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, "")
    .replace(/</g, "＜").replace(/>/g, "＞").replace(/&/g, "＆")
}

function notificationTitle(value) {
  // Omarchy's notification command parses known flags before the headline.
  var title = textForMarkupSink(value, 2048)
  return title.charAt(0) === "-" ? "\u2060" + title : title
}

function localDateKey(value) {
  var text = String(value || "")
  if (/^\d{4}-\d{2}-\d{2}$/.test(text)) return text
  var date = new Date(text)
  if (isNaN(date.getTime())) return ""
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function pad2(value) {
  return Number(value) < 10 ? "0" + Number(value) : String(Number(value))
}

function eventDateKeys(event) {
  var first = localDateKey(event && event.start)
  if (!first) return []
  var last = localDateKey(event && event.end)
  if (!last || last < first) return [first]

  var cursor = new Date(first + "T12:00:00")
  var end = new Date(last + "T12:00:00")
  // All-day calendar end values are exclusive. Timed events ending exactly at
  // midnight should not appear to span into the following day either.
  if (event.all_day || /T00:00(?::00)?(?:Z|[+-]\d\d:\d\d)?$/.test(String(event.end || "")))
    end.setDate(end.getDate() - 1)

  var keys = []
  while (cursor <= end && keys.length < 370) {
    keys.push(localDateKey(cursor.toISOString()))
    cursor.setDate(cursor.getDate() + 1)
  }
  return keys.length > 0 ? keys : [first]
}

function eventsForDate(events, dateKey) {
  var list = []
  for (var i = 0; i < (events || []).length; i++) {
    if (eventDateKeys(events[i]).indexOf(String(dateKey)) !== -1) list.push(events[i])
  }
  return list
}

function countForDate(events, dateKey) {
  return eventsForDate(events, dateKey).length
}

function calendarColor(event) {
  var color = String((event && event.calendar_color) || "")
  return /^#[0-9a-fA-F]{6}$/.test(color) ? color : ""
}

var URL_PATTERN = /https:\/\/[^\s<>"']+/gi
var CONFERENCE_HOSTS = ["meet.google.com", "teams.microsoft.com", "teams.live.com",
  "whereby.com", "meet.jit.si", "jitsi.me", "gotomeeting.com"]
var CONFERENCE_DOMAINS = ["zoom.us", "zoom.com", "webex.com"]

function conferenceHost(url) {
  if (url.length > 2048 || /[\\\x00-\x20\x7f-\x9f]/.test(url)
      || /%(?:0[0-9a-f]|1[0-9a-f]|7f|25|5c)/i.test(url)
      || /%(?![0-9a-f]{2})/i.test(url)
      || /&(?:#[0-9]+|#x[0-9a-f]+|[a-z]+)(?:;|$)/i.test(url)) return ""
  var match = /^https:\/\/([a-z0-9.-]+)(?:[/?#]|$)/i.exec(url)
  if (!match) return ""
  var host = match[1].toLowerCase()
  if (host.length > 253 || !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(host)) return ""
  if (CONFERENCE_HOSTS.indexOf(host) >= 0) return host
  for (var i = 0; i < CONFERENCE_DOMAINS.length; i++) {
    var domain = CONFERENCE_DOMAINS[i]
    if (host === domain || host.slice(-(domain.length + 1)) === "." + domain) return host
  }
  return ""
}

function extractUrls(text) {
  var urls = []
  var seen = {}
  var match
  var source = boundedText(text, 10000)
  URL_PATTERN.lastIndex = 0
  while (urls.length < 8 && (match = URL_PATTERN.exec(source)) !== null) {
    var url = String(match[0]).replace(/[.,;:!?)\]}]+$/, "")
    if (conferenceHost(url) !== "" && !seen[url]) {
      seen[url] = true
      urls.push(url)
    }
  }
  return urls
}

// Meeting links first: Google puts Meet links in the event's dedicated
// conference field, then in the location. Approved conference-host URLs
// from the description follow, in order and without duplicates.
function eventMeetingLinks(event) {
  var links = []
  var seen = {}
  function add(list) {
    for (var i = 0; i < list.length; i++) {
      if (!seen[list[i]]) {
        seen[list[i]] = true
        links.push(list[i])
      }
    }
  }
  add(extractUrls(event && event.conference_url))
  add(extractUrls(event && event.url))
  add(extractUrls(event && event.location))
  add(extractUrls(event && event.description))
  return links
}

// Same identity the agenda rows use, so reminders and the next-event
// highlight can address the exact event occurrence on screen.
function eventKeyFor(event) {
  var identity = event.instance_id || (String(event.uid || "") + ":" + String(event.start || ""))
  return String(event.calendar || "") + ":" + String(identity)
}

function calendarColorsForDate(events, dateKey) {
  var dayEvents = eventsForDate(events, dateKey)
  var colors = []
  for (var i = 0; i < dayEvents.length; i++) {
    var color = calendarColor(dayEvents[i])
    if (color !== "" && colors.indexOf(color) === -1) colors.push(color)
  }
  return colors
}

// Build this once as a cache snapshot arrives instead of asking every one of
// the 42 month cells to scan every event whenever the visible month changes.
// Each entry deliberately carries both the events and its unique calendar
// colours, making grid dots, tooltips, and the agenda simple lookups.
function indexEventsByDate(events) {
  var index = {}
  for (var i = 0; i < (events || []).length; i++) {
    var event = events[i]
    var keys = eventDateKeys(event)
    var color = calendarColor(event)
    for (var j = 0; j < keys.length; j++) {
      var key = keys[j]
      if (!index[key]) index[key] = { events: [], colors: [] }
      index[key].events.push(event)
      if (color !== "" && index[key].colors.indexOf(color) === -1)
        index[key].colors.push(color)
    }
  }
  return index
}

if (typeof module !== "undefined") {
  module.exports = { parseBridgeOutput, parseSyncResult, parsePendingState, parseMinutes,
    eventDurationMinutes, editableReminder, eventEditorText, rebaseEditorText, eventReminderOffsets, dueReminderOffsets,
    eventMeetingLinks, eventKeyFor, textForMarkupSink, notificationTitle }
}
