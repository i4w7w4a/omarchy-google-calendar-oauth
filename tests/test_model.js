const assert = require('node:assert/strict')
const { test } = require('node:test')
const model = require('../CalendarModel.js')

test('minutes must be whole numbers within their input range', () => {
  assert.equal(model.parseMinutes('1', 1, 10080), 1)
  assert.equal(model.parseMinutes('10080', 1, 10080), 10080)
  assert.equal(model.parseMinutes('40320', 1, 40320), 40320)
  for (const value of ['', '0', '10081', '1.5', '2e1', '-5', true, [], null]) {
    assert.equal(model.parseMinutes(value, 1, 10080), null)
  }
})

test('recurring editor uses master duration and reminder independently', () => {
  const event = { duration_minutes: 75, series_duration_minutes: 15,
    reminder: { mode: 'custom', minutes: 12 }, series_reminder: { mode: 'none' } }
  assert.equal(model.eventDurationMinutes(event, false), 75)
  assert.equal(model.eventDurationMinutes(event, true), 15)
  assert.deepEqual(model.editableReminder(event, false), { mode: 'custom', minutes: 12 })
  assert.deepEqual(model.editableReminder(event, true), { mode: 'none' })
  assert.deepEqual(model.editableReminder({ reminder: { mode: 'keep' } }), { mode: 'keep' })
  assert.deepEqual(model.editableReminder({ reminder: { mode: 'custom', minutes: 0 } }), { mode: 'keep' })
  assert.deepEqual(model.editableReminder(null), { mode: 'default' })
})

test('legacy cached duration is read without rounding or replacing long events', () => {
  const event = { start: '2026-11-13T09:00:00+03:00', end: '2026-11-13T10:15:00+03:00' }
  assert.equal(model.eventDurationMinutes(event), 75)
  assert.equal(model.eventDurationMinutes({ ...event, duration_minutes: 10500 }), null)
  assert.equal(model.eventDurationMinutes({ ...event, end: '2026-11-13T10:15:15+03:00' }), null)
  assert.equal(model.eventDurationMinutes({ start: '2026-11-13', end: '2026-11-14', all_day: true }), null)
})

test('changing recurring scope updates only the untouched title and description', () => {
  const event = { recurring: true, title: 'One-off title', description: 'One-off description',
    series_title: 'Series title', series_description: '' }
  const instance = model.eventEditorText(event, 'instance')
  const series = model.eventEditorText(event, 'series')
  assert.deepEqual(series, { title: 'Series title', description: '' })
  assert.deepEqual(model.rebaseEditorText(instance, instance, series), series)
  assert.deepEqual(model.rebaseEditorText({ ...instance, title: 'Draft title' }, instance, series),
    { title: 'Draft title', description: '' })
  assert.deepEqual(model.rebaseEditorText({ ...series, description: 'Draft description' }, series, instance),
    { title: 'One-off title', description: 'Draft description' })
  assert.deepEqual(model.eventEditorText({ recurring: true, title: 'Legacy' }, 'series'),
    { title: 'Legacy', description: '' })
  assert.deepEqual(model.eventEditorText({ title: 'Standalone', series_title: 'Other' }, 'series'),
    { title: 'Standalone', description: '' })
})

test('desktop reminders follow the configured offset and local all-day start', () => {
  const event = { start: '2026-11-13T12:00:00+03:00' }
  const start = Date.parse(event.start)
  assert.deepEqual(model.dueReminderOffsets(event, start - 5 * 60000), [5])
  assert.deepEqual(model.dueReminderOffsets(event, start + 1000), [0])
  assert.deepEqual(model.dueReminderOffsets(event, start - 1000), [])
  assert.deepEqual(model.dueReminderOffsets({ ...event, reminder: { mode: 'none' } }, start), [])
  const custom = { ...event, reminder: { mode: 'custom', minutes: 40320 } }
  assert.deepEqual(model.dueReminderOffsets(custom, start - 40320 * 60000), [40320])
  assert.deepEqual(model.dueReminderOffsets(custom, start - 5 * 60000), [])
  assert.deepEqual(model.eventReminderOffsets({ reminder: { mode: 'keep' }, reminder_offsets: [0, 60, 60, -1, 40321] }), [0, 60])
  const allDay = { start: '2026-11-13', all_day: true, reminder: { mode: 'custom', minutes: 1440 } }
  assert.deepEqual(model.dueReminderOffsets(allDay, new Date(2026, 10, 13).getTime() - 1440 * 60000), [1440])
  assert.deepEqual(model.eventReminderOffsets({ ...allDay, reminder: { mode: 'default' } }), [])
})

test('cache and pending state have explicit success and validation', () => {
  assert.deepEqual(model.parsePendingState('{"pending_count":3,"retry_at":1794596800}'),
    { count: 3, retryable: true, retryAt: 1794596800000 })
  assert.deepEqual(model.parsePendingState('{"pending_count":1,"auto_retry":false}'),
    { count: 1, retryable: false, retryAt: 0 })
  assert.deepEqual(model.parsePendingState('{"pending_count":0}'), { count: 0, retryable: true, retryAt: 0 })
  assert.equal(model.parsePendingState('{"pending_count":"3"}'), null)
  assert.equal(model.parsePendingState('{"pending_count":-1}'), null)
  assert.equal(model.parsePendingState(''), null)
  assert.equal(model.parseSyncResult('{"ok":true,"sync":"pending"}').sync, 'pending')
  assert.equal(model.parseSyncResult('Saved in Google'), null)
  const valid = { start: '2026-11-13T09:00:00+03:00', title: '<b>Literal title</b>' }
  assert.deepEqual(model.parseBridgeOutput(JSON.stringify({ ok: true,
    events: [null, { start: 'bogus' }, { start: '12' }, valid] })).events, [valid])
  assert.notEqual(model.eventKeyFor({ calendar: 'first', instance_id: 'id' }),
    model.eventKeyFor({ calendar: 'second', instance_id: 'id' }))
})

test('meeting action requires an approved HTTPS authority', () => {
  const allowed = 'https://meet.google.com/abc-defg-hij'
  const zoom = 'https://region.zoom.us/j/123456789?pwd=value'
  const attempts = [
    'http://meet.google.com/not-https',
    'https://evil.example/?host=meet.google.com',
    'https://meet.google.com.evil.example/a',
    'https://meet.google.com@evil.example/a',
    'https://evil.example@meet.google.com/a',
    'https://evilzoom.us/j/1',
    'https://meet.google.com%40evil.example/a',
    'https://meet.google.com\\@evil.example/a',
    'https://meet.google.com/%0a/a',
    'https://meet.google.com/a?b=&#34;',
    'https://meet.google.com:444/a',
    'https://meet.google.com/a?b=%2',
  ]
  assert.deepEqual(model.eventMeetingLinks({ description: attempts.join(' ') }), [])
  assert.deepEqual(model.eventMeetingLinks({ conference_url: allowed, location: `(${zoom}).`,
    description: `Duplicate: ${allowed}` }), [allowed, zoom])
})

test('calendar tooltips and notification bodies cannot supply markup', () => {
  const attacker = '<img src="https://example.invalid/" /> &#x3c;b&#x3e;\u0000 &lt;a&gt;'
  const result = model.textForMarkupSink(attacker, 200)
  assert.doesNotMatch(result, /[<>&\u0000]/)
  assert.equal(model.textForMarkupSink('обычный текст', 200), 'обычный текст')
  assert.equal(model.textForMarkupSink('12345', 3), '123')
  assert.equal(model.notificationTitle('--exec'), '\u2060--exec')
  assert.doesNotMatch(model.notificationTitle(attacker), /[<>&\u0000]/)
})
