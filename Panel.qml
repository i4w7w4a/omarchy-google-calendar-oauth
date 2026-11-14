import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "CalendarModel.js" as CalendarModel

// The clock's calendar popup: a month grid with ISO week numbers, built to
// sit beside the weather panel — same hero-over-detail composition, same
// spacing scale, same small-caps labels.
//
// The grid is a read-out rather than a picker: today is the only marked
// day, and the only thing that moves is which month is on screen —
// chevrons, the scroll wheel, and the arrow keys all step it.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "re_pick.google-calendar-clock"
  ipcTarget: "re_pick.google-calendar-clock"
  manageIpc: false
  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  // Keep this in step with manifest.json so the installed panel can identify
  // its release without reading files from Quickshell's sandbox.
  readonly property string pluginVersion: "1.2"

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // a read-out, not a picker, so there is no per-day cursor to keep in sync.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Memento mori, for anyone who goes looking: double-tapping the year bar
  // asks for a birth year and a life expectancy, and a second bar tracks one
  // against the other. A birth year rather than an age, so it keeps counting
  // on its own. Without one the bar stays hidden.
  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), labelLocale.firstDayOfWeek)
  readonly property var labelLocale: Qt.locale(I18n.formatLocale)
  readonly property string monthYearLabel: I18n.t("clock.monthYear")
    .arg(labelLocale.standaloneMonthName(viewMonth, Locale.LongFormat))
    .arg(viewDate.toLocaleDateString(labelLocale, "yyyy"))
  readonly property string nextWeekStartLabel: Model.capitalizeDateNames(labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat), labelLocale, today)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)

  // Caldir is the only component that reads the local ICS store. Keeping the
  // QML side on a small JSON contract avoids reimplementing recurrence and
  // timezone parsing in the shell.
  property var calendarEvents: []
  property var calendarEventsByDate: ({})
  property string calendarError: ""
  property bool calendarLoading: false
  property bool calendarPulling: false
  property bool calendarAutoPrefetching: false
  property bool calendarScheduledRefreshing: false
  readonly property bool calendarCreating: calendarWriteProcess.running && calendarWriteProcess.action === "create"
  readonly property bool calendarMutating: calendarWriteProcess.running && calendarWriteProcess.action !== "create"
  readonly property bool calendarPushing: calendarPushProcess.running && calendarPushProcess.manual
  property bool calendarPushArmed: false
  property bool calendarStatusLoading: false
  property string calendarSyncMessage: ""
  property string calendarSaveState: ""
  property int calendarPendingCount: 0
  property bool calendarRetryable: true
  property double calendarRetryAt: 0
  readonly property bool calendarAutoPush: String(setting("calendarAutoPush", true)).toLowerCase() !== "false"
  property int calendarRetryDelay: 30000
  readonly property string calendarStateDirectory: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state") + "/omarchy-calendar"
  readonly property string calendarFeedback: calendarSyncMessage !== "" ? calendarSyncMessage
    : calendarPendingCount > 0 && !calendarRetryable ? strings.t("sync.pendingReview")
    : calendarPendingCount > 0 || calendarSaveState === "pending" ? strings.t("sync.pending")
    : calendarSaveState === "synced" ? strings.t("sync.synced")
    : calendarSaveState === "deleted" ? strings.t("sync.deletedLocal")
    : calendarSaveState === "local" ? strings.t("sync.savedLocal") : ""

  // Any calendar operation in flight: the agenda area below the grid goes
  // inert (controls disabled) and a spinner row takes its place. The grid
  // itself stays browsable so the popup never feels frozen.
  readonly property bool calendarBusy: calendarPulling || calendarPushing
    || calendarCreating || calendarMutating || calendarStatusLoading
  readonly property string calendarBusyLabel: calendarPulling
    ? strings.t("message.s0")
    : calendarPushing ? strings.t("message.s1")
    : calendarCreating ? strings.t("message.s2")
    : calendarMutating ? strings.t("message.s3")
    : strings.t("message.s4")
  readonly property bool calendarProgressVisible: calendarBusy
    || calendarAutoPrefetching || (calendarLoading && calendarEvents.length === 0)
  readonly property string calendarProgressLabel: calendarBusy
    ? calendarBusyLabel
    : calendarAutoPrefetching ? strings.t("message.s5")
    : strings.t("message.s6")
  property string calendarPullOutput: ""
  property string calendarAutoPrefetchOutput: ""
  property string calendarScheduledRefreshOutput: ""
  property string calendarStatusOutput: ""
  property var calendarStatusEntries: []
  property bool calendarRuntimeMissing: false
  property bool calendarRuntimeChecked: false
  property int calendarLoadedYear: -1
  property int calendarRequestedYear: -1
  property string calendarRangeStart: ""
  property string calendarRangeEnd: ""
  readonly property string lastCalendarPull: String(setting("lastCalendarPull", ""))
  readonly property int calendarPrefetchMonths: Math.max(1, Math.min(24, parseInt(setting("calendarPrefetchMonths", 6), 10) || 6))
  property string agendaDateKey: todayKey
  property bool editingEvent: false
  property var selectedAgendaEvent: null
  property string eventMutationScope: "instance"
  property bool calendarDeleteArmed: false
  property bool settingsOpen: false
  property bool authStatusLoading: false
  property string authStatusOutput: ""
  property string authMode: "unknown"
  property string authStatusError: ""

  property string eventRepeatMode: "none"
  property string originalEventRecurrenceRule: ""
  property bool eventAllDayEditing: true
  readonly property bool eventTitleOnlyEditing: !!selectedAgendaEvent
    && !!selectedAgendaEvent.event_title_only
  readonly property var durationOptions: minuteOptions(CalendarModel.DURATION_PRESETS,
    selectedAgendaEvent && editorSchedule(selectedAgendaEvent, eventMutationScope).durationChoice === "keep")
  readonly property var reminderOptions: {
    var options = [
      { value: "default", label: strings.t("editor.reminderDefault") },
      { value: "none", label: strings.t("editor.reminderNone") }
    ]
    var keep = selectedAgendaEvent && CalendarModel.editableReminder(selectedAgendaEvent, eventMutationScope === "series").mode === "keep"
    return options.concat(minuteOptions(CalendarModel.REMINDER_PRESETS, keep))
  }
  property string expandedAgendaInstanceId: ""
  property real calendarFrozenTop: -1
  readonly property var eventRepeatOptions: [
    { value: "none", icon: "1", label: strings.t("message.s16") },
    { value: "daily", icon: strings.t("editor.dailyShort"), label: strings.t("message.s17") },
    { value: "weekly", icon: strings.t("editor.weeklyShort"), label: strings.t("message.s18") },
    { value: "monthly", icon: strings.t("editor.monthlyShort"), label: strings.t("message.s19") },
    { value: "yearly", icon: strings.t("editor.yearlyShort"), label: strings.t("message.s20") }
  ]
  readonly property var agendaEvents: calendarEventsByDate[agendaDateKey]
    ? calendarEventsByDate[agendaDateKey].events : []
  readonly property var calendarSlugs: {
    var slugs = []
    for (var i = 0; i < calendarEvents.length; i++) {
      var slug = String(calendarEvents[i].calendar || "")
      if (slug !== "" && slugs.indexOf(slug) === -1) slugs.push(slug)
    }
    slugs.sort()
    return slugs
  }

  // ---- Event reminders and the next-event highlight. eventClock is bumped
  //      every minute by SystemClock so both the highlight and the reminder
  //      sweep re-evaluate without polling timers.
  property date eventClock: new Date()
  property var reminderQueue: []
  property string reminderMinute: ""
  property var reminderKeys: Object.create(null)
  property bool eventNotificationsEnabled: String(setting("eventNotifications", "true")).toLowerCase() !== "false"
  readonly property string calendarPanelPosition: String(setting("calendarPanelPosition", "original")).toLowerCase() === "screen-center"
    ? "screen-center" : "original"
  readonly property string calendarColorMode: String(setting("calendarColorMode", "google")).toLowerCase() === "theme"
    ? "theme" : "google"
  readonly property int settingsCardWidth: Style.space(300)
  readonly property int settingsCardGap: Style.gapsOut
  readonly property bool settingsCardOnRight: panel.cardOrigin.x + panel.contentWidth
    + settingsCardGap + settingsCardWidth <= panel.screenW - panel.margin
  readonly property bool settingsCardOnLeft: panel.cardOrigin.x
    - settingsCardGap - settingsCardWidth >= panel.margin
  readonly property color themeCalendarPrimary: Commons.Color.accent
  readonly property color themeCalendarSecondary: root.colorKey(Commons.Color.urgent) !== root.colorKey(Commons.Color.accent)
    ? Commons.Color.urgent
    : (root.colorKey(Commons.Color.muted) !== root.colorKey(Commons.Color.accent) ? Commons.Color.muted : Commons.Color.foreground)

  onSettingsOpenChanged: {
    if (root.settingsOpen) {
      root.refreshAuthStatus()
      Qt.callLater(function() { settingsCard.forceActiveFocus() })
    } else if (root.opened) {
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  onCalendarAutoPushChanged: {
    if (calendarAutoPush) scheduleCalendarPush(250)
    else calendarPushRetry.stop()
  }

  // The agenda's highlighted event: the next timed event of the displayed
  // day. Today that means still upcoming; on any other day it is the first
  // timed event of that day.
  readonly property string nextTimedEventKey: root.computeNextTimedEventKey()

  function helperPath(name) {
    var url = String(Qt.resolvedUrl("scripts/" + name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function setupPath() {
    var url = String(Qt.resolvedUrl("setup"))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function uninstallPath() {
    var url = String(Qt.resolvedUrl("uninstall"))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function toggleSettings() {
    root.settingsOpen = !root.settingsOpen
  }

  function refreshAuthStatus() {
    if (authStatusProcess.running) return
    root.authStatusLoading = true
    root.authStatusOutput = ""
    root.authStatusError = ""
    authStatusProcess.command = [root.helperPath("calendar-auth-mode"), "status", "--json"]
    authStatusProcess.running = true
  }

  function setCalendarColorMode(mode) {
    var next = String(mode || "") === "theme" ? "theme" : "google"
    if (next === root.calendarColorMode) return
    root.persistSettings({ calendarColorMode: next })
  }

  function setCalendarPanelPosition(position) {
    var next = String(position || "") === "original" ? "original" : "screen-center"
    if (next === root.calendarPanelPosition) return
    root.persistSettings({ calendarPanelPosition: next })
    if (root.opened) {
      Qt.callLater(function() {
        if (!root.opened) return
        root.calendarFrozenTop = next === "screen-center" ? root.calendarCenteredTop() : -1
      })
    }
  }

  // Asks the runtime probe whether the Caldir binaries are installed. The
  // result lands in calendarRuntimeMissing, which drives the setup banner
  // and the sync-action gates.
  function probeCalendarRuntime() {
    if (calendarRuntimeProbeProcess.running) return
    calendarRuntimeProbeProcess.command = [root.helperPath("calendar-runtime-check")]
    calendarRuntimeProbeProcess.running = true
  }

  function runCalendarSetup() {
    if (!root.bar || typeof root.bar.run !== "function") return
    var launcher = "omarchy-launch-floating-terminal-with-presentation"
    root.bar.run(launcher + " " + Util.shellQuote(root.setupPath()))
    root.close()
  }

  // Uninstall restores the built-in clock in the center of the bar.
  function runPluginUninstall() {
    if (!root.bar || typeof root.bar.run !== "function") return
    var launcher = "omarchy-launch-floating-terminal-with-presentation"
    root.close()
    root.bar.run(launcher + " " + Util.shellQuote(root.uninstallPath()))
  }


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  function open() {
    calendarFrozenTop = -1
    refresh()
    if (calendarLoadedYear !== viewYear) refreshCalendar(viewYear)
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) {
        if (root.calendarPanelPosition === "screen-center")
          root.calendarFrozenTop = root.calendarCenteredTop()
        setCenterHoverRevealSuppressed(true)
      }
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Dismissing the panel mid-edit would otherwise leave the inputs up,
    // waiting behind a closed popup for the next time it opens.
    if (root.editingLife) root.cancelEditingLife()
    if (root.editingEvent) {
      root.editingEvent = false
      root.selectedAgendaEvent = null
      root.calendarDeleteArmed = false
      calendarDeleteConfirmation.stop()
    }
    // Status and operation notes belong to this one opening of the popup;
    // reopening the clock should return to its compact agenda.
    root.calendarStatusEntries = []
    root.calendarSyncMessage = ""
    root.calendarSaveState = ""
    root.calendarPushArmed = false
    root.calendarDeleteArmed = false
    root.settingsOpen = false
    root.expandedAgendaInstanceId = ""
    calendarPushConfirmation.stop()
    calendarDeleteConfirmation.stop()
    root.calendarFrozenTop = -1
    calendarScroll.contentY = 0
    root.controller.hide()
  }

  function calendarVerticalBounds() {
    var position = root.bar ? root.bar.position : "bottom"
    var top = Style.gapsOut
    var bottom = panel.screenH - Style.gapsOut
    if (position === "top") top = panel.barThickness + Style.gapsOut
    if (position === "bottom") bottom = panel.screenH - panel.barThickness - Style.gapsOut
    return { top: top, bottom: Math.max(top + 1, bottom) }
  }

  function calendarCenteredTop() {
    var bounds = root.calendarVerticalBounds()
    return Math.max(bounds.top, Math.round(bounds.top + (bounds.bottom - bounds.top - panel.contentHeight) / 2))
  }

  function calendarFittedHeight(implicitHeight) {
    var desired = Math.max(panel.verticalContentInset,
      (Number(implicitHeight) || 0) + panel.verticalContentInset)
    if (panel.screenH <= 0) return Math.round(desired)
    var bounds = root.calendarVerticalBounds()
    var top = root.calendarFrozenTop >= 0 ? root.calendarFrozenTop : bounds.top
    // A centered calendar keeps its opening y position as its contents grow.
    // Let it use the screen below that fixed edge; using bounds.bottom here
    // reserves the bottom bar a second time and clips the event form.
    var bottom = root.calendarFrozenTop >= 0 ? panel.screenH - Style.gapsOut : bounds.bottom
    return Math.round(Math.min(desired, Math.max(panel.verticalContentInset, bottom - top)))
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    // Omarchy's PluginBarApi now exposes this state as read-only.  Use its
    // setter when available, retaining the assignment fallback for older
    // shell releases.
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    root.agendaDateKey = root.todayKey
  }

  function refreshCalendar(targetYear) {
    var year = targetYear === undefined ? viewYear : Number(targetYear)
    if (!isFinite(year)) year = viewYear
    if (calendarProcess.running) {
      calendarReloadAfterPull.restart()
      return
    }
    calendarLoading = true
    calendarRequestedYear = year
    calendarProcess.command = [root.helperPath("calendar-cache-read")]
    calendarProcess.running = true
  }

  function selectAgendaDate(dateKey) {
    agendaDateKey = dateKey
    expandedAgendaInstanceId = ""
    // The agenda follows the grid in a scrollable panel. A day click should
    // reveal its result immediately instead of making people discover that
    // there is more content below the fold.
    Qt.callLater(function() {
      calendarScroll.contentY = Math.max(0, calendarScroll.contentHeight - calendarScroll.height)
    })
  }

  function minuteOptions(presets, keep) {
    var options = presets.map(function(minutes) {
      return { value: String(minutes), label: strings.t("editor.minutes").arg(I18n.formatNumber(minutes)) }
    })
    options.push({ value: "custom", label: strings.t("editor.customMinutes") })
    if (keep) options.unshift({ value: "keep", label: strings.t("editor.keepCurrent") })
    return options
  }

  function editorSchedule(event, scope) {
    var series = event && event.recurring && scope === "series"
    var allDay = !event || (series && typeof event.series_all_day === "boolean" ? event.series_all_day : !!event.all_day)
    var start = event && (series && event.series_start ? event.series_start : event.start)
    var duration = CalendarModel.eventDurationMinutes(event, series)
    if (allDay) duration = 60
    var reminder = CalendarModel.editableReminder(event, series)
    return {
      allDay: allDay,
      time: allDay ? "" : root.eventTimeLabel({ start: start }),
      duration: duration,
      durationChoice: duration === null ? "keep" : CalendarModel.minuteChoice(duration, CalendarModel.DURATION_PRESETS),
      reminder: reminder,
      reminderChoice: reminder.mode === "custom" ? CalendarModel.minuteChoice(reminder.minutes, CalendarModel.REMINDER_PRESETS) : reminder.mode
    }
  }

  function applyEditorSchedule(schedule, keepTime, keepDuration, keepReminder) {
    if (!keepTime) {
      root.eventAllDayEditing = schedule.allDay
      eventTimeField.text = schedule.time
    }
    if (!keepDuration) {
      eventDurationChoice.value = schedule.durationChoice
      eventDurationField.text = schedule.duration === null ? "" : String(schedule.duration)
      eventDurationChoice.edited = false
    }
    if (!keepReminder) {
      eventReminderChoice.value = schedule.reminderChoice
      eventReminderField.text = schedule.reminder.minutes === undefined ? "" : String(schedule.reminder.minutes)
      eventReminderChoice.edited = false
    }
  }

  function setEventMutationScope(scope) {
    if (scope === eventMutationScope || !selectedAgendaEvent) return
    var previous = editorSchedule(selectedAgendaEvent, eventMutationScope)
    var keepTime = previous.allDay !== eventAllDayEditing || (!previous.allDay && previous.time !== eventTimeField.text)
    var rebased = CalendarModel.rebaseEditorText(
      { title: eventTitleField.text, description: eventDescriptionField.text },
      CalendarModel.eventEditorText(selectedAgendaEvent, eventMutationScope),
      CalendarModel.eventEditorText(selectedAgendaEvent, scope))
    eventMutationScope = scope
    if (eventTitleField.text !== rebased.title) eventTitleField.text = rebased.title
    if (eventDescriptionField.text !== rebased.description) eventDescriptionField.text = rebased.description
    applyEditorSchedule(editorSchedule(selectedAgendaEvent, scope), keepTime,
      eventDurationChoice.edited, eventReminderChoice.edited)
    calendarDeleteArmed = false
    calendarDeleteConfirmation.stop()
    calendarSyncMessage = ""
  }

  function revealEditorControl(control) {
    if (!control || !control.visible || !root.editingEvent) return
    var y = control.mapToItem(calendarColumn, 0, 0).y
    var bottom = y + control.height + Style.space(8)
    if (y < calendarScroll.contentY) calendarScroll.contentY = Math.max(0, y - Style.space(8))
    else if (bottom > calendarScroll.contentY + calendarScroll.height)
      calendarScroll.contentY = Math.min(bottom - calendarScroll.height,
        Math.max(0, calendarScroll.contentHeight - calendarScroll.height))
  }

  function dropdownSpace(choice) {
    // Dropdown draws into the window overlay. Keep enough scrollable space
    // below its trigger to fit the visible menu inside the output.
    return Math.min(choice.options.length, 8) * (choice.popupRowHeight + Style.spacing.labelGap) + Style.space(14)
  }

  function revealDropdown(choice) {
    if (!choice.popupOpen) return
    Qt.callLater(function() {
      if (!choice.popupOpen) return
      var available = Math.min(calendarScroll.height, panel.screenH - calendarScroll.mapToItem(null, 0, 0).y)
      if (available <= 0) return
      var y = choice.mapToItem(calendarColumn, 0, 0).y
      var target = Math.max(calendarScroll.contentY, y + choice.height + dropdownSpace(choice) - available)
      calendarScroll.contentY = Math.min(target, Math.max(0, calendarScroll.contentHeight - calendarScroll.height))
    })
  }

  function showEditorError(key, control) {
    calendarSyncMessage = strings.t(key)
    control.forceActiveFocus()
    Qt.callLater(function() { root.revealEditorControl(calendarFeedbackRow) })
  }

  function startCreatingEvent() {
    selectedAgendaEvent = null
    eventMutationScope = "series"
    eventRepeatMode = "none"
    originalEventRecurrenceRule = ""
    calendarDeleteArmed = false
    calendarSyncMessage = ""
    expandedAgendaInstanceId = ""
    editingEvent = true
    applyEditorSchedule(editorSchedule(null, "series"), false, false, false)
    eventTitleField.text = ""
    eventDescriptionField.text = ""
    eventRepeatCountField.text = ""
    Qt.callLater(function() {
      eventTitleField.forceActiveFocus()
      revealEditorControl(eventTitleField)
    })
  }

  function startEditingEvent(event) {
    if (!event || event.calendar_read_only) {
      calendarSyncMessage = strings.t("message.s7")
      return
    }
    if (event.event_read_only) {
      calendarSyncMessage = strings.t("detail.s49")
      return
    }
    selectedAgendaEvent = event
    eventMutationScope = event.recurring ? "instance" : "series"
    originalEventRecurrenceRule = String(event.recurrence_rule || "")
    eventRepeatMode = event.recurring ? recurrenceModeFromRule(originalEventRecurrenceRule) : "none"
    calendarDeleteArmed = false
    calendarSyncMessage = ""
    expandedAgendaInstanceId = ""
    editingEvent = true
    applyEditorSchedule(editorSchedule(event, eventMutationScope), false, false, false)
    var text = CalendarModel.eventEditorText(event, eventMutationScope)
    eventTitleField.text = text.title
    eventDescriptionField.text = text.description
    eventRepeatCountField.text = event.recurring ? recurrenceCountFromRule(root.originalEventRecurrenceRule) : ""
    Qt.callLater(function() {
      eventTitleField.forceActiveFocus()
      eventTitleField.selectAll()
      revealEditorControl(eventTitleField)
    })
  }

  function cancelEditingEvent() {
    if (calendarCreating || calendarMutating) return
    editingEvent = false
    selectedAgendaEvent = null
    calendarDeleteArmed = false
    calendarDeleteConfirmation.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function saveLocalEvent() {
    if (!root.editingEvent || calendarWriteProcess.running) return
    var title = String(eventTitleField.text || "").trim()
    var rawDescription = String(eventDescriptionField.text || "")
    var description = rawDescription.trim()
    var descriptionEdited = !selectedAgendaEvent
      || (!eventTitleOnlyEditing && rawDescription !== CalendarModel.eventEditorText(selectedAgendaEvent, eventMutationScope).description)
    var time = String(eventTimeField.text || "").trim()
    // An empty masked TextField exposes its literal separator (`:`) through
    // `text`. Do not send the mask literal to the helper.
    if (!/[0-9]/.test(time)) time = ""
    var repeatCount = String(eventRepeatCountField.text || "").trim()
    if (title === "") {
      showEditorError("message.s8", eventTitleField)
      return
    }
    if (Array.from(title).length > 1024) {
      showEditorError("editor.titleTooLong", eventTitleField)
      return
    }
    if (descriptionEdited && Array.from(description).length > 10000) {
      showEditorError("editor.descriptionTooLong", eventDescriptionField)
      return
    }
    var scheduleEditable = !selectedAgendaEvent
      || (selectedAgendaEvent.recurring && eventMutationScope === "series")
    if (scheduleEditable && repeatCount !== ""
        && (!/^\d+$/.test(repeatCount) || Number(repeatCount) < 2 || Number(repeatCount) > 999)) {
      showEditorError("detail.s50", eventRepeatCountField)
      return
    }
    if (!root.eventAllDayEditing && !/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(time)) {
      showEditorError("message.s9", eventTimeField)
      return
    }
    if (root.eventAllDayEditing) time = ""
    var durationChoice = eventDurationChoice.value
    var duration = null
    if (!eventAllDayEditing && !eventTitleOnlyEditing && (!selectedAgendaEvent || eventDurationChoice.edited) && durationChoice !== "keep") {
      duration = CalendarModel.parseMinutes(durationChoice === "custom" ? eventDurationField.text : durationChoice,
        1, CalendarModel.MAX_DURATION_MINUTES)
      if (duration === null) {
        showEditorError("editor.invalidDuration", eventDurationField)
        return
      }
    }
    var reminder = { mode: "keep" }
    if (!eventTitleOnlyEditing && (!selectedAgendaEvent || eventReminderChoice.edited)) {
      var choice = eventReminderChoice.value
      reminder = { mode: choice }
      if (choice !== "keep" && choice !== "default" && choice !== "none") {
        var minutes = CalendarModel.parseMinutes(choice === "custom" ? eventReminderField.text : choice,
          1, CalendarModel.MAX_REMINDER_MINUTES)
        if (minutes === null) {
          showEditorError("editor.invalidReminder", eventReminderField)
          return
        }
        reminder = { mode: "custom", minutes: minutes }
      }
    }

    var request = { title: title, time: time, reminder: reminder }
    if (descriptionEdited) request.description = description
    if (duration !== null) request.duration_minutes = duration
    if (selectedAgendaEvent) {
      request.action = "edit"
      request.scope = eventMutationScope
      request.calendar = String(selectedAgendaEvent.calendar || "")
      request.uid = String(selectedAgendaEvent.uid || "")
      request.instance_id = String(selectedAgendaEvent.instance_id || "")
      request.start = String(selectedAgendaEvent.start || "")
      request.end = String(selectedAgendaEvent.end || "")
      request.all_day = eventAllDayEditing
      request.recurrence_rule = recurrenceRuleForMutation(repeatCount)
      request.expected_revision = selectedEventRevision()
      runCalendarWrite("edit", request)
    } else {
      request.date = agendaDateKey
      request.repeat = eventRepeatMode
      request.count = eventRepeatMode === "none" || repeatCount === "" ? "" : Number(repeatCount)
      runCalendarWrite("create", request)
    }
  }

  function runCalendarWrite(action, request) {
    calendarSyncMessage = ""
    calendarDeleteArmed = false
    calendarDeleteConfirmation.stop()
    calendarWriteProcess.action = action
    calendarWriteProcess.payload = JSON.stringify(request)
    calendarWriteProcess.output = ""
    calendarWriteProcess.diagnostic = ""
    calendarWriteProcess.command = [root.helperPath(action === "create" ? "calendar-create" : "calendar-mutate"), "--stdin"]
    calendarWriteProcess.stdinEnabled = true
    calendarWriteProcess.running = true
  }

  function deleteSelectedEvent() {
    if (!selectedAgendaEvent || calendarWriteProcess.running) return
    if (!calendarDeleteArmed) {
      calendarDeleteArmed = true
      calendarSyncMessage = strings.t("editor.confirmDelete").arg(deleteConfirmationMessage())
      calendarDeleteConfirmation.restart()
      return
    }
    runCalendarWrite("delete", {
      action: "delete",
      scope: eventMutationScope,
      calendar: String(selectedAgendaEvent.calendar || ""),
      uid: String(selectedAgendaEvent.uid || ""),
      instance_id: String(selectedAgendaEvent.instance_id || ""),
      expected_revision: selectedEventRevision(),
      confirm: true
    })
  }

  function selectedEventRevision() {
    if (eventMutationScope === "series" && selectedAgendaEvent.series_revision)
      return selectedAgendaEvent.series_revision
    return selectedAgendaEvent.revision || undefined
  }

  function mutationTargetLabel() {
    if (!selectedAgendaEvent || !selectedAgendaEvent.recurring) return strings.t("detail.s0")
    return eventMutationScope === "series" ? strings.t("detail.s1") : strings.t("detail.s2")
  }

  function deleteConfirmationMessage() {
    if (!selectedAgendaEvent || !selectedAgendaEvent.recurring)
      return strings.t("detail.s3")
    if (eventMutationScope === "series")
      return strings.t("detail.s4")
    return strings.t("detail.s5")
  }

  function deleteTooltipText() {
    if (calendarDeleteArmed)
      return strings.t("dynamic.confirmDelete").arg(mutationTargetLabel())
    if (!selectedAgendaEvent || !selectedAgendaEvent.recurring)
      return strings.t("detail.s6")
    return eventMutationScope === "series"
      ? strings.t("detail.s7")
      : strings.t("detail.s8")
  }

  function eventRepeatLabel() {
    for (var i = 0; i < eventRepeatOptions.length; i++)
      if (eventRepeatOptions[i].value === eventRepeatMode) return eventRepeatOptions[i].label
    return strings.t("message.s16")
  }

  function recurrenceModeFromRule(rule) {
    var match = /(?:^|;)FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(?:;|$)/i.exec(String(rule || ""))
    return match ? match[1].toLowerCase() : "weekly"
  }

  function recurrenceCountFromRule(rule) {
    var match = /(?:^|;)COUNT=(\d+)(?:;|$)/i.exec(String(rule || ""))
    return match ? match[1] : ""
  }

  function recurrenceRuleFromControls(count) {
    var frequency = String(eventRepeatMode || "none").toUpperCase()
    if (frequency === "NONE") return ""
    return "FREQ=" + frequency + (count === "" ? "" : ";COUNT=" + count)
  }

  function recurrenceRuleForMutation(count) {
    if (!selectedAgendaEvent || !selectedAgendaEvent.recurring || eventMutationScope !== "series")
      return "keep"
    var originalMode = recurrenceModeFromRule(originalEventRecurrenceRule)
    var originalCount = recurrenceCountFromRule(originalEventRecurrenceRule)
    if (eventRepeatMode === originalMode && count === originalCount) return "keep"
    return recurrenceRuleFromControls(count)
  }

  function eventTooltip(dateKey) {
    var entry = calendarEventsByDate[dateKey]
    var events = entry ? entry.events : []
    if (events.length === 0) return strings.t("detail.s9")
    var titles = []
    for (var i = 0; i < events.length && i < 3; i++)
      titles.push(CalendarModel.textForMarkupSink(events[i].title || strings.t("message.s10"), 240))
    if (events.length > titles.length) titles.push(strings.t("dynamic.more").arg(events.length - titles.length))
    return titles.join("\n")
  }

  function eventCount(dateKey) {
    var entry = calendarEventsByDate[dateKey]
    return entry ? entry.events.length : 0
  }

  function eventColors(dateKey) {
    var entry = calendarEventsByDate[dateKey]
    if (!entry) return []
    if (root.calendarColorMode === "google") return entry.colors

    var colors = []
    for (var i = 0; i < entry.events.length; i++) {
      var color = root.themeCalendarColor(String(entry.events[i].calendar || ""))
      if (colors.indexOf(color) === -1) colors.push(color)
    }
    return colors
  }

  function themeCalendarColor(slug) {
    var value = String(slug || "")
    var index = root.calendarSlugs.indexOf(value)
    if (index < 0) index = 0
    return index % 2 === 0 ? root.themeCalendarPrimary : root.themeCalendarSecondary
  }

  function colorKey(color) {
    return [color.r.toFixed(4), color.g.toFixed(4), color.b.toFixed(4), color.a.toFixed(4)].join(":")
  }

  function displayCalendarColor(event) {
    if (root.calendarColorMode === "theme")
      return root.themeCalendarColor(String((event && event.calendar) || ""))
    return CalendarModel.calendarColor(event) || Commons.Color.accent
  }

  function calendarColorForSlug(slug) {
    if (root.calendarColorMode === "theme") return root.themeCalendarColor(slug)
    for (var i = 0; i < calendarEvents.length; i++) {
      if (String(calendarEvents[i].calendar || "") === String(slug)) {
        var color = CalendarModel.calendarColor(calendarEvents[i])
        if (color !== "") return color
      }
    }
    return Commons.Color.accent
  }

  function parseCalendarStatus(text) {
    var entries = []
    var active = null
    var lines = CalendarModel.boundedText(text, 16000).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = String(lines[i]).trim()
      if (line === "") continue
      var match = /^📅\s+(.+?)(\s+\(read-only\))?$/.exec(line)
      if (match) {
        active = { slug: match[1].slice(0, 256), readOnly: !!match[2], details: [] }
        entries.push(active)
      } else if (active) {
        active.details.push(line.slice(0, 512))
      }
    }
    return entries
  }

  function eventTimeLabel(event) {
    if (event && event.all_day) return strings.t("message.s11")
    var start = new Date(event && event.start)
    if (isNaN(start.getTime())) return ""
    return Qt.formatTime(start, "HH:mm")
  }

  function eventKeyFor(event) {
    return CalendarModel.eventKeyFor(event)
  }

  // Highlight only the next upcoming timed event on today. Past and future
  // days are historical/planning views, not a current-next-event state.
  function computeNextTimedEventKey() {
    var now = root.eventClock
    var isToday = root.agendaDateKey === Model.keyForDate(now)
    if (!isToday) return ""
    var entry = root.calendarEventsByDate[root.agendaDateKey]
    if (!entry || !entry.events) return ""
    var bestKey = ""
    var bestStart = -1
    for (var i = 0; i < entry.events.length; i++) {
      var event = entry.events[i]
      if (event.all_day) continue
      var start = new Date(String(event.start || ""))
      if (isNaN(start.getTime())) continue
      if (start.getTime() < now.getTime()) continue
      if (bestStart < 0 || start.getTime() < bestStart) {
        bestStart = start.getTime()
        bestKey = root.eventKeyFor(event)
      }
    }
    return bestKey
  }

  function ownsBackgroundWork() {
    if (!root.hostWidget || !root.bar || typeof root.bar.moduleWidgets !== "function") return true
    var widgets = root.bar.moduleWidgets(root.moduleName)
    return widgets.length === 0 || widgets[0] === root.hostWidget
  }

  // A minute is evaluated once across the bar's screens. Saved keys also
  // prevent duplicate notifications if Shell restarts in that minute.
  function evaluateEventReminders() {
    if (!ownsBackgroundWork()) return
    if (hasLegacyReminders()) {
      if (!reminderProcess.running) {
        var legacy = root.settings.calendarNotified
        try {
          if (typeof legacy === "string") legacy = JSON.parse(legacy)
        } catch (error) {
          legacy = null
        }
        if (!legacy || typeof legacy !== "object" || Array.isArray(legacy)) legacy = {}
        reminderProcess.startRequest({ payload: JSON.stringify(legacy) }, true)
      }
      return
    }
    if (!root.eventNotificationsEnabled || root.calendarEvents.length === 0) return
    var now = root.eventClock
    var minute = String(Math.floor(now.getTime() / 60000))
    if (reminderMinute !== minute) {
      reminderMinute = minute
      reminderKeys = Object.create(null)
    }
    var queued = []
    for (var i = 0; i < root.calendarEvents.length; i++) {
      var event = root.calendarEvents[i]
      var offsets = CalendarModel.dueReminderOffsets(event, now.getTime())
      for (var j = 0; j < offsets.length; j++) {
        var notifyKey = root.eventKeyFor(event) + "|" + offsets[j]
        if (reminderKeys[notifyKey]) continue
        reminderKeys[notifyKey] = true
        queued.push({ payload: root.reminderPayload(event, offsets[j], notifyKey), minute: minute })
      }
    }
    if (queued.length > 0) {
      reminderQueue = reminderQueue.concat(queued)
      sendNextReminder()
    }
  }

  function hasLegacyReminders() {
    return root.settings && Object.prototype.hasOwnProperty.call(root.settings, "calendarNotified")
  }

  function reminderPayload(event, offset, key) {
    var title = CalendarModel.boundedText(event.title || strings.t("message.s10"), 2048)
      .replace(/[\ud800-\udbff]$/, "")
    var start = new Date(CalendarModel.eventStartTime(event))
    var time = event.all_day ? strings.t("message.s11") : start.toLocaleString(labelLocale, "d MMM, HH:mm")
    var description = (offset === 0 ? strings.t("detail.s11")
      : strings.tn("reminder.startsIn", offset).arg(I18n.formatNumber(offset))) + "\n" + time
    var links = CalendarModel.eventMeetingLinks(event)
    return JSON.stringify({ key: key, headline: title, body: description, link: links[0] || "" })
  }

  function sendNextReminder() {
    if (reminderProcess.running || reminderQueue.length === 0 || hasLegacyReminders()) return
    var item = reminderQueue[0]
    reminderQueue = reminderQueue.slice(1)
    reminderProcess.startRequest(item, false)
  }

  function lastPullLabel() {
    if (lastCalendarPull === "") return strings.t("detail.s12")
    var date = new Date(lastCalendarPull)
    return isNaN(date.getTime()) ? strings.t("detail.s13") : strings.t("dynamic.lastPull").arg(date.toLocaleString(labelLocale, "d MMM, HH:mm"))
  }

  function pullFromGoogle() {
    if (calendarPullProcess.running || calendarAutoPrefetchProcess.running
        || calendarScheduledRefreshProcess.running || calendarPushProcess.running) return
    if (calendarPendingCount > 0) {
      calendarSyncMessage = strings.t("sync.pullPending")
      return
    }
    if (root.calendarRuntimeMissing) {
      root.probeCalendarRuntime()
      root.calendarSyncMessage = strings.t("detail.s14")
      return
    }
    calendarPulling = true
    calendarSyncMessage = strings.t("message.s0")
    calendarPullOutput = ""
    calendarPullProcess.command = [
      root.helperPath("calendar-pull"), "--pending", prefetchStartDate(), prefetchEndDate()
    ]
    calendarPullProcess.running = true
  }

  function pushToGoogle() {
    if (calendarPushProcess.running) return
    if (root.calendarRuntimeMissing) {
      root.probeCalendarRuntime()
      root.calendarSyncMessage = strings.t("detail.s14")
      return
    }
    if (!calendarPushArmed) {
      calendarPushArmed = true
      calendarSyncMessage = strings.t(calendarRetryable ? "detail.s15" : "sync.confirmPendingReview")
      calendarPushConfirmation.restart()
      return
    }
    calendarPushConfirmation.stop()
    calendarPushArmed = false
    runCalendarPush(true)
  }

  function pushTooltip() {
    if (!calendarRetryable) return strings.t(calendarPushArmed ? "sync.confirmPendingReview" : "sync.checkPending")
    return strings.t(calendarPushArmed ? "message.s26" : "message.s27")
  }

  function runCalendarPush(manual) {
    calendarPushRetry.stop()
    if (manual) calendarSyncMessage = ""
    calendarPushProcess.manual = manual
    calendarPushProcess.output = ""
    calendarPushProcess.command = manual
      ? [root.helperPath("calendar-push"), "--confirm", "--json"]
      : [root.helperPath("calendar-push"), "--auto"]
    calendarPushProcess.running = true
  }

  function markCalendarPushSuccess() {
    calendarSaveState = "synced"
    calendarPendingFile.reload()
  }

  function publishCalendarPushSuccess() {
    if (root.hostWidget) root.hostWidget.broadcast("markCalendarPushSuccess")
    else root.markCalendarPushSuccess()
  }

  function scheduleCalendarPush(delay) {
    if (!calendarAutoPush || calendarPendingCount === 0 || !calendarRetryable || !calendarRuntimeChecked
        || calendarRuntimeMissing || calendarPushRetry.running || calendarPushProcess.running) return
    calendarPushRetry.interval = Math.min(300000, Math.max(delay, calendarRetryAt - Date.now() + 200))
    calendarPushRetry.start()
  }

  function attemptCalendarPush() {
    if (!calendarAutoPush || calendarPendingCount === 0 || !calendarRetryable || calendarRuntimeMissing) return
    if (calendarRetryAt > Date.now()) {
      scheduleCalendarPush(250)
      return
    }
    if (calendarBusy || root.editingEvent || calendarAutoPrefetchProcess.running || calendarScheduledRefreshProcess.running) {
      scheduleCalendarPush(calendarRetryDelay)
      return
    }
    runCalendarPush(false)
  }

  function applyCalendarPendingState(state) {
    if (!state) return
    var hadPending = calendarPendingCount > 0
    var wasRetryable = calendarRetryable
    var previousRetryAt = calendarRetryAt
    calendarPendingCount = state.count
    calendarRetryable = state.retryable
    calendarRetryAt = state.retryAt
    if (state.count > 0 && state.retryable) {
      if (state.retryAt !== previousRetryAt) calendarPushRetry.stop()
      scheduleCalendarPush(!hadPending || !wasRetryable || state.retryAt !== previousRetryAt ? 250 : calendarRetryDelay)
    } else {
      calendarPushRetry.stop()
      if (state.count === 0) {
        calendarRetryDelay = 30000
        if (calendarSyncMessage === strings.t("sync.pullPending")) calendarSyncMessage = ""
      }
    }
  }

  function prefetchStartDate() {
    // A manual pull should include the month being viewed, not merely the
    // window relative to today. Keep the current year too, so returning home
    // after browsing ahead never leaves an empty cache behind.
    return Model.keyForDate(new Date(Math.min(today.getFullYear(), viewYear), 0, 1))
  }

  function prefetchEndDate() {
    var focus = new Date(viewYear, viewMonth, 1)
    var current = new Date(today.getFullYear(), today.getMonth(), 1)
    if (focus < current) focus = current
    var lastMonth = new Date(focus.getFullYear(), focus.getMonth() + calendarPrefetchMonths, 1)
    var currentYearEnd = new Date(today.getFullYear(), 11, 1)
    if (lastMonth < currentYearEnd) lastMonth = currentYearEnd
    return Model.keyForDate(new Date(lastMonth.getFullYear(), lastMonth.getMonth() + 1, 0))
  }

  function prefetchRangeLabel() {
    var start = new Date(prefetchStartDate() + "T12:00:00")
    var end = new Date(prefetchEndDate() + "T12:00:00")
    return Qt.formatDate(start, "MMM yyyy") + "–" + Qt.formatDate(end, "MMM yyyy")
  }

  // When browsing reaches the last two cached months, fetch another window
  // in a separate process. The current snapshot keeps rendering meanwhile;
  // the updater atomically replaces it and notifies the shell when ready.
  function prefetchThresholdEndDate() {
    return Model.keyForDate(new Date(viewYear, viewMonth + 3, 0))
  }

  function automaticPrefetchStartDate() {
    var lastCachedDay = new Date(calendarRangeEnd + "T12:00:00")
    lastCachedDay.setDate(lastCachedDay.getDate() + 1)
    return Model.keyForDate(lastCachedDay)
  }

  function maybeExtendCalendarCache() {
    if (calendarAutoPrefetchProcess.running || calendarPullProcess.running
        || calendarScheduledRefreshProcess.running || calendarPushProcess.running
        || calendarPendingCount > 0 || calendarRangeEnd === "") return
    if (calendarRangeEnd >= prefetchThresholdEndDate()) return

    var rangeEnd = prefetchEndDate()
    if (calendarRangeEnd >= rangeEnd) return
    calendarAutoPrefetching = true
    calendarAutoPrefetchOutput = ""
    calendarAutoPrefetchProcess.command = [
      root.helperPath("calendar-pull"),
      automaticPrefetchStartDate(), rangeEnd
    ]
    calendarAutoPrefetchProcess.running = true
  }

  function checkCalendarStatus() {
    if (calendarStatusProcess.running) return
    if (root.calendarRuntimeMissing) {
      root.probeCalendarRuntime()
      root.calendarSyncMessage = strings.t("detail.s14")
      return
    }
    calendarStatusLoading = true
    calendarSyncMessage = strings.t("message.s4")
    calendarStatusOutput = ""
    calendarStatusEntries = []
    calendarStatusProcess.command = [root.helperPath("calendar-status")]
    calendarStatusProcess.running = true
  }

  function scheduledCalendarRefresh() {
    if (calendarScheduledRefreshProcess.running || calendarPullProcess.running
        || calendarAutoPrefetchProcess.running || calendarPushProcess.running
        || calendarPendingCount > 0 || calendarRuntimeMissing || authMode === "none" || !ownsBackgroundWork()) return
    calendarScheduledRefreshing = true
    calendarScheduledRefreshOutput = ""
    calendarScheduledRefreshProcess.command = [root.helperPath("calendar-pull"), "--pending"]
    calendarScheduledRefreshProcess.running = true
  }

  function calendarStatus() {
    return JSON.stringify({
      loading: calendarLoading,
      error: calendarError,
      events: calendarEvents.length,
      selectedDate: agendaDateKey,
      selectedEvents: agendaEvents.length,
      loadedYear: calendarLoadedYear,
      pending: calendarPendingCount,
      autoPush: calendarAutoPush
    })
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
    if (calendarLoadedYear !== next.year) refreshCalendar(next.year)
    maybeExtendCalendarCache()
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values, removeLegacyReminders) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) {
      if (existing !== "id" && !(removeLegacyReminders && existing === "calendarNotified"))
        entry[existing] = root.settings[existing]
    }
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // English short day names, matching the rest of the interface.
  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      root.eventClock = clock.date
      root.evaluateEventReminders()
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      root.today = clock.date
      if (followToday) root.goToToday()
    }
  }

  FileView {
    id: calendarPendingFile
    path: root.calendarStateDirectory + "/pending.json"
    preload: true
    watchChanges: true
    printErrors: false
    onLoaded: root.applyCalendarPendingState(CalendarModel.parsePendingState(text()))
    onFileChanged: reload()
  }

  FileView {
    path: root.calendarStateDirectory + "/cache.json"
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: calendarReloadAfterPull.restart()
  }

  Process {
    id: calendarProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = CalendarModel.parseBridgeOutput(text)
        root.calendarError = parsed.error
        if (parsed.error === "") {
          root.calendarEvents = parsed.events
          root.calendarEventsByDate = CalendarModel.indexEventsByDate(parsed.events)
          root.calendarRangeStart = parsed.rangeStart
          root.calendarRangeEnd = parsed.rangeEnd
          root.calendarLoadedYear = root.calendarRequestedYear
        }
      }
    }
    onExited: function(exitCode) {
      root.calendarLoading = false
      if (exitCode !== 0 && root.calendarError === "")
        root.calendarError = strings.t("detail.s16")
      if (exitCode === 0 && root.calendarError === "") {
        root.evaluateEventReminders()
        if (root.opened) root.maybeExtendCalendarCache()
      }
    }
  }

  Process {
    id: calendarPullProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarPullOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarPullOutput += text
    }
    onExited: function(exitCode) {
      root.calendarPulling = false
      if (exitCode === 0) {
        root.persistSettings({ lastCalendarPull: new Date().toISOString() })
        root.calendarSyncMessage = root.lastPullLabel()
        root.calendarStatusEntries = []
        root.calendarStatusOutput = ""
        calendarReloadAfterPull.restart()
      } else if (exitCode === 127) {
        root.calendarRuntimeMissing = true
        root.calendarSyncMessage = strings.t("detail.s14")
      } else if (exitCode === 75) {
        calendarPendingFile.reload()
        root.calendarSyncMessage = strings.t(root.calendarPendingCount > 0 ? "sync.pullPending" : "sync.busy")
      } else {
        root.calendarSyncMessage = CalendarModel.boundedText(root.calendarPullOutput, 1024) || strings.t("detail.s17")
      }
    }
  }

  Process {
    id: calendarAutoPrefetchProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarAutoPrefetchOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarAutoPrefetchOutput += text
    }
    onExited: function(exitCode) {
      root.calendarAutoPrefetching = false
      if (exitCode === 0)
        calendarReloadAfterPull.restart()
      else if (exitCode === 75)
        calendarPendingFile.reload()
      else
        root.calendarSyncMessage = CalendarModel.boundedText(root.calendarAutoPrefetchOutput, 1024) || strings.t("detail.s18")
    }
  }

  Process {
    id: calendarScheduledRefreshProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarScheduledRefreshOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarScheduledRefreshOutput += text
    }
    onExited: function(exitCode) {
      root.calendarScheduledRefreshing = false
      if (exitCode === 0) {
        calendarReloadAfterPull.restart()
      } else if (exitCode === 127) {
        root.calendarRuntimeMissing = true
        if (root.calendarEvents.length === 0)
          root.calendarError = strings.t("detail.s14")
      } else if (exitCode === 75) {
        calendarPendingFile.reload()
      } else if (root.calendarEvents.length === 0) {
        root.calendarError = CalendarModel.boundedText(root.calendarScheduledRefreshOutput, 1024) || strings.t("detail.s19")
      }
    }
  }

  Process {
    id: calendarWriteProcess
    property string action: ""
    property string payload: ""
    property string output: ""
    property string diagnostic: ""
    onStarted: {
      write(payload + "\n")
      stdinEnabled = false
      payload = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: calendarWriteProcess.output = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: calendarWriteProcess.diagnostic = text
    }
    onExited: function(exitCode) {
      var result = CalendarModel.parseSyncResult(output)
      if (exitCode !== 0 || !result || !result.ok) {
        var stale = result && result.reason === "stale_revision"
        root.calendarSyncMessage = stale ? strings.t("editor.staleEvent")
          : exitCode === 75 ? strings.t("sync.busy")
          : CalendarModel.boundedText(diagnostic || (result && result.error), 1024)
          || strings.t(action === "create" ? "detail.s22" : "detail.s23")
        if (stale) calendarReloadAfterPull.restart()
        Qt.callLater(function() {
          if (root.editingEvent) root.revealEditorControl(calendarFeedbackRow)
        })
        return
      }
      root.editingEvent = false
      root.selectedAgendaEvent = null
      root.calendarDeleteArmed = false
      root.calendarStatusEntries = []
      root.calendarSaveState = result.sync === "pending" || result.sync === "synced" ? result.sync
        : action === "delete" ? "deleted" : "local"
      if (result.sync === "pending" && root.calendarPendingCount === 0)
        root.applyCalendarPendingState({ count: 1, retryable: true, retryAt: 0 })
      calendarPendingFile.reload()
      calendarReloadAfterPull.restart()
    }
  }

  Process {
    id: calendarPushProcess
    property bool manual: false
    property string output: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: calendarPushProcess.output = text
    }
    onExited: function(exitCode) {
      var result = CalendarModel.parseSyncResult(output)
      if (exitCode === 0 && result && result.ok && (result.sync === "synced" || result.sync === "idle")) {
        if (result.sync === "synced") {
          root.publishCalendarPushSuccess()
        } else {
          if (root.calendarSaveState === "pending") root.calendarSaveState = ""
          if (manual) root.calendarSyncMessage = strings.t("detail.s28")
        }
        root.calendarRetryDelay = 30000
        root.calendarStatusEntries = []
        root.calendarStatusOutput = ""
        calendarReloadAfterPull.restart()
      } else if (exitCode === 127) {
        root.calendarRuntimeMissing = true
        if (manual) root.calendarSyncMessage = strings.t("detail.s14")
      } else {
        if (manual) {
          if (!root.calendarRetryable) root.calendarSyncMessage = ""
          else root.calendarSyncMessage = strings.t(exitCode === 75 ? "sync.busy" : "detail.s25")
        }
        root.scheduleCalendarPush(root.calendarRetryDelay)
        root.calendarRetryDelay = Math.min(300000, root.calendarRetryDelay * 2)
      }
      calendarPendingFile.reload()
    }
  }

  Timer {
    id: calendarPushRetry
    repeat: false
    onTriggered: root.attemptCalendarPush()
  }

  Timer {
    id: calendarPushConfirmation
    interval: 8000
    repeat: false
    onTriggered: {
      root.calendarPushArmed = false
      if (!root.calendarPushing)
        root.calendarSyncMessage = strings.t("detail.s26")
    }
  }

  Timer {
    id: calendarDeleteConfirmation
    interval: 8000
    repeat: false
    onTriggered: {
      root.calendarDeleteArmed = false
      if (!root.calendarMutating)
        root.calendarSyncMessage = strings.t("detail.s27")
    }
  }

  Timer {
    id: calendarReloadAfterPull
    interval: 400
    repeat: false
    onTriggered: root.refreshCalendar(root.viewYear)
  }

  // Preload the existing snapshot shortly after the shell creates this
  // plugin. Opening the popup normally needs no process or disk work.
  Timer {
    id: calendarPreloadTimer
    interval: 1200
    repeat: false
    running: true
    onTriggered: {
      root.refreshCalendar(root.today.getFullYear())
      root.probeCalendarRuntime()
    }
  }

  // Re-probe each time the panel opens so the setup banner clears as soon
  // as setup has finished (setup itself closes the panel).
  onOpenedChanged: {
    if (root.opened) {
      root.probeCalendarRuntime()
      root.refreshAuthStatus()
    }
  }

  Timer {
    interval: 2500
    repeat: false
    running: true
    onTriggered: root.scheduledCalendarRefresh()
  }

  Timer {
    interval: 30 * 60 * 1000
    repeat: true
    running: true
    onTriggered: root.scheduledCalendarRefresh()
  }

  Process {
    id: calendarStatusProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarStatusOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calendarStatusOutput += text
    }
    onExited: function(exitCode) {
      root.calendarStatusLoading = false
      if (exitCode === 0) {
        root.calendarStatusEntries = root.parseCalendarStatus(root.calendarStatusOutput)
        root.calendarSyncMessage = root.calendarStatusEntries.length > 0 ? "" : strings.t("detail.s28")
      } else if (exitCode === 127) {
        root.calendarRuntimeMissing = true
        root.calendarSyncMessage = strings.t("detail.s14")
      } else {
        root.calendarSyncMessage = root.calendarStatusOutput || strings.t("detail.s29")
      }
    }
  }

  Process {
    id: calendarRuntimeProbeProcess
    onExited: function(exitCode) {
      root.calendarRuntimeMissing = exitCode !== 0
      root.calendarRuntimeChecked = true
      if (exitCode === 0) root.scheduleCalendarPush(250)
    }
  }

  Process {
    id: authStatusProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.authStatusOutput += text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.authStatusOutput += text
    }
    onExited: function(exitCode) {
      root.authStatusLoading = false
      if (exitCode !== 0) {
        root.authStatusError = strings.t("detail.s30")
        return
      }
      try {
        var status = JSON.parse(root.authStatusOutput)
        root.authMode = status.mode === "goa" || status.mode === "direct" ? "connected" : "none"
        root.authStatusError = ""
      } catch (error) {
        root.authStatusError = strings.t("detail.s30")
      }
    }
  }

  Process {
    id: reminderProcess
    property var item: null
    property bool migrating: false

    function startRequest(next, migrate) {
      item = next
      migrating = migrate
      command = migrate ? [root.helperPath("calendar-notify"), "--migrate"]
                        : [root.helperPath("calendar-notify")]
      stdinEnabled = true
      running = true
    }

    onStarted: {
      write(item.payload + "\n")
      stdinEnabled = false
    }

    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.calendarSyncMessage = strings.t("detail.s31")
      if (!migrating && exitCode === 69 && !item.retried) {
        reminderRetry.items = reminderRetry.items.concat([{ payload: item.payload, minute: item.minute, retried: true }])
        if (!reminderRetry.running) reminderRetry.start()
      }
      if (migrating && exitCode === 0) {
        root.persistSettings({}, true)
        Qt.callLater(root.evaluateEventReminders)
      }
      item = null
      Qt.callLater(root.sendNextReminder)
    }
  }

  Timer {
    id: reminderRetry
    property var items: []
    interval: 2000
    onTriggered: {
      var minute = String(Math.floor(Date.now() / 60000))
      if (root.eventNotificationsEnabled) {
        root.reminderQueue = root.reminderQueue.concat(items.filter(function(item) { return item.minute === minute }))
        root.sendNextReminder()
      }
      items = []
    }
  }

  // Keep KeyboardPanel's real gap untouched: it also defines the clickable
  // bar strip. Screen-center mode positions only its internal card, reached
  // through the content holder that owns our key catcher; original mode lets
  // KeyboardPanel restore the stock clock's card-origin binding.
  Binding {
    target: keyCatcher.parent && keyCatcher.parent.parent ? keyCatcher.parent.parent : null
    property: "y"
    when: root.calendarPanelPosition === "screen-center"
    value: root.calendarFrozenTop >= 0 ? root.calendarFrozenTop : root.calendarCenteredTop()
  }

  // RC2 clips the entire card while its height animates upward. The settings
  // card lives outside that card's bounds, so keep it visible during growth.
  Binding {
    target: keyCatcher.parent && keyCatcher.parent.parent ? keyCatcher.parent.parent : null
    property: "clip"
    when: root.settingsOpen && panel.morph >= 1
    value: false
  }

  // On a left or right bar KeyboardPanel already centers the card vertically,
  // so screen-center mode also needs to override its horizontal origin.
  Binding {
    target: keyCatcher.parent && keyCatcher.parent.parent ? keyCatcher.parent.parent : null
    property: "x"
    when: root.calendarPanelPosition === "screen-center" && root.bar
      && (root.bar.position === "left" || root.bar.position === "right")
    value: Math.max(panel.margin, Math.round((panel.screenW - panel.contentWidth) / 2))
  }

  component SettingsChoiceButton: Button {
    property string optionValue: ""
    property string currentValue: ""
    signal chosen(string value)

    selected: optionValue === currentValue
    bordered: true
    focusable: true
    // Keep the fill stable on hover. Button still paints its immediate hover
    // border, but avoids the animated bright-then-dim fill transition.
    color: selected ? Style.selectedFillFor(foreground, accent) : background
    onClicked: chosen(optionValue)
  }

  component EventMinutesField: TextField {
    id: minutesField
    required property int maximum
    width: parent.width
    height: Style.space(26)
    foreground: root.contentForeground
    font.family: root.contentFontFamily
    font.pixelSize: Style.font.bodySmall
    verticalPadding: 0
    placeholderText: strings.t("editor.minuteRange").arg(I18n.formatNumber(maximum))
    inputMethodHints: Qt.ImhDigitsOnly
    validator: IntValidator { bottom: 1; top: minutesField.maximum }
    Keys.onReturnPressed: root.saveLocalEvent()
    Keys.onEnterPressed: root.saveLocalEvent()
    Keys.onEscapePressed: root.cancelEditingEvent()
    onActiveFocusChanged: if (activeFocus) root.revealEditorControl(this)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: root.calendarPanelPosition === "screen-center"
      ? root.calendarFittedHeight(calendarColumn.implicitHeight)
      : panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || root.editingEvent || root.settingsOpen
      Keys.onEscapePressed: if (root.editingEvent) root.cancelEditingEvent()
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
      }

      Flickable {
        id: calendarScroll
        objectName: "calendarScroll"
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width
        Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

        Column {
          id: calendarColumn
          // Never narrower than the grid. The popup width is capped to what
          // the screen allows, and a fixed seven-column grid would otherwise
          // lose its last days off the edge instead of scrolling.
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)
          // Keep the last control clear of the card edge when the agenda
          // switches from its compact list to the event editor.
          bottomPadding: Style.space(12) + (eventDurationChoice.popupOpen ? root.dropdownSpace(eventDurationChoice)
            : eventReminderChoice.popupOpen ? root.dropdownSpace(eventReminderChoice) : 0)

          // ---- Hero: today, centered. Once the view has stepped back
          //      it is also the way home — clicking the date you are
          //      looking for beats hunting for a reset button.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                textFormat: Text.PlainText
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Commons.Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                textFormat: Text.PlainText
                id: heroDate
                anchors.verticalCenter: parent.verticalCenter
                text: Model.capitalizeDateNames(root.today.toLocaleDateString(root.labelLocale, I18n.t("clock.dayMonthFormat")), root.labelLocale, root.today)
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Commons.Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: I18n.t("clock.backToToday")
                fontFamily: root.contentFontFamily
              }
            }

            PanelActionButton {
              anchors.top: parent.top
              anchors.right: parent.right
              iconText: "󰒓"
              tooltipText: root.settingsOpen ? strings.t("settings.close") : strings.t("settings.title")
              foreground: root.settingsOpen ? Commons.Color.accent : root.contentForeground
              fontFamily: root.contentFontFamily
              focusable: true
              onClicked: root.toggleSettings()
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: I18n.t("clock.born")
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: I18n.t("clock.year")
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 0
                  leftPadding: Style.space(6)
                  text: I18n.t("clock.liveTo")
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                textFormat: Text.PlainText
                id: yearLabel
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.formatNumber(root.today.getFullYear())
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                textFormat: Text.PlainText
                id: yearPercent
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.formatNumber(root.yearDonePercent) + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Commons.Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori. Only here once someone has gone looking and
          //      given an age; the same rail as the year above it, measured
          //      against a nominal lifetime.
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                textFormat: Text.PlainText
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.t("clock.life")
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                textFormat: Text.PlainText
                id: lifePercent
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.formatNumber(root.lifeDonePercent) + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Commons.Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              onWheel: function(event) {
                // Horizontal wheels and touchpad side-scrolls report y === 0;
                // without this they would every one read as "next month".
                if (event.angleDelta.y === 0) return
                root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Commons.Color.accent)
                    : "transparent"

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: I18n.t("clock.weekShort")
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Commons.Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: I18n.t("clock.startWeeksOn").arg(root.nextWeekStartLabel)
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    textFormat: Text.PlainText
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  required property var modelData
                  spacing: root.cellSpacing

                  Text {
                    textFormat: Text.PlainText
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: I18n.formatNumber(modelData.week)
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      required property var modelData

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      // Today is outlined, not filled: a lit-up block shouts
                      // over a grid this quiet.
                      color: root.agendaDateKey === modelData.key
                        ? Style.hoverFillFor(root.contentForeground, Commons.Color.accent)
                        : "transparent"
                      border.width: (modelData.today || root.agendaDateKey === modelData.key)
                        ? Style.spacing.hairline : 0
                      border.color: Style.normalBorderFor(root.contentForeground, Commons.Color.accent)

                      Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        text: I18n.formatNumber(modelData.day)
                        color: modelData.inMonth
                          ? (modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.today
                      }

                      Row {
                        visible: root.eventCount(modelData.key) > 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(4)
                        spacing: Style.space(3)

                        Repeater {
                          model: root.eventColors(modelData.key)

                          Rectangle {
                            required property var modelData
                            width: Style.space(5)
                            height: width
                            radius: width / 2
                            color: modelData || Commons.Color.accent
                          }
                        }
                      }

                      MouseArea {
                        id: dayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectAgendaDate(modelData.key)
                      }

                      PanelToolTip {
                        visible: dayMouse.containsMouse
                        text: root.eventTooltip(modelData.key)
                        fontFamily: root.contentFontFamily
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter, drawn only beside the
            // day rows so it does not cut through the header band.
            Rectangle {
              x: gridColumn.x + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                textFormat: Text.PlainText
                id: monthLabel
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                // Fixed width so the chevrons hold still between a
                // "MAY 2026" and a "SEPTEMBER 2026".
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: root.monthYearLabel.toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: I18n.rightToLeft ? "󰅂" : "󰅁"
                tooltipText: I18n.t("clock.previousMonth")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: I18n.rightToLeft ? "󰅁" : "󰅂"
                tooltipText: I18n.t("clock.nextMonth")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          // ---- Hairline dividing the calendar rail above from the agenda
          //      controls below, matching the divider convention used by
          //      other Omarchy panels.
          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.contentForeground
            opacity: 0.12
          }

          // ---- Calendar agenda and editor.
          Column {
            id: agendaSection
            width: gridColumn.width
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)
            enabled: !root.calendarBusy

            Item {
              width: parent.width
              height: agendaLabel.implicitHeight

              Text {
                textFormat: Text.PlainText
                id: agendaLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: new Date(root.agendaDateKey + "T12:00:00").toLocaleDateString(root.labelLocale, "dddd, d MMMM").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                PanelActionButton {
                  iconText: "󰐕"
                  tooltipText: strings.t("dynamic.addEvent").arg(root.agendaDateKey)
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: !root.editingEvent && !root.calendarRuntimeMissing
                  onClicked: root.startCreatingEvent()
                }

                PanelActionButton {
                  iconText: "󰄬"
                  tooltipText: strings.t("agenda.checkSync")
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: !root.calendarStatusLoading && !root.calendarPulling
                    && !root.calendarAutoPrefetching && !root.calendarScheduledRefreshing
                  onClicked: root.checkCalendarStatus()
                }

                PanelActionButton {
                  iconText: "↓"
                  tooltipText: strings.t("agenda.pull")
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: !calendarPushProcess.running && !root.calendarPulling && !root.calendarAutoPrefetching
                    && !root.calendarStatusLoading && !root.calendarScheduledRefreshing
                  onClicked: root.pullFromGoogle()
                }

                PanelActionButton {
                  iconText: "↑"
                  tooltipText: root.pushTooltip()
                  foreground: root.calendarPushArmed ? Commons.Color.accent : root.contentForeground
                  fontFamily: root.contentFontFamily
                  enabled: !calendarPushProcess.running && !root.calendarPulling
                    && !root.calendarAutoPrefetching && !root.calendarScheduledRefreshing
                  onClicked: root.pushToGoogle()
                }

              }
            }

            // ---- Hairline separating the agenda toolbar (day label and
            //      sync actions) from the rows below it.
            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: 0.12
            }

            BorderSurface {
              visible: root.calendarRuntimeMissing || root.authMode === "none"
              width: parent.width
              height: setupChoices.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.barForeground, root.barForeground)
              borderSpec: Border.controlSpec("normal", root.barForeground, Commons.Color.accent)

              Column {
                id: setupChoices
                x: Style.space(6)
                y: Style.space(6)
                width: parent.width - Style.space(12)
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: strings.t("settings.connectDescription")
                  color: root.barForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Button {
                  text: strings.t("settings.connect")
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(6)
                  verticalPadding: Style.space(2)
                  foreground: root.barForeground
                  fontFamily: root.contentFontFamily
                  bordered: true
                  onClicked: root.runCalendarSetup()
                }
              }
            }

            Column {
              visible: root.calendarStatusEntries.length > 0
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                model: root.calendarStatusEntries

                Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(2)

                  Row {
                    spacing: Style.space(7)

                    Rectangle {
                      width: Style.space(6)
                      height: width
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: root.calendarColorForSlug(modelData.slug)
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.readOnly ? strings.t("dynamic.readOnly").arg(modelData.slug) : modelData.slug
                      color: Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Repeater {
                    model: modelData.details

                    Text {
                      textFormat: Text.PlainText
                      required property var modelData
                      leftPadding: Style.space(13)
                      width: parent.width
                      wrapMode: Text.Wrap
                      text: modelData
                      color: Qt.darker(root.contentForeground, 1.7)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            Row {
              visible: root.editingEvent && root.selectedAgendaEvent && root.selectedAgendaEvent.recurring
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("editor.applyTo")
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              PanelActionButton {
                iconText: "1"
                tooltipText: strings.t("detail.s36")
                foreground: root.eventMutationScope === "instance" ? Commons.Color.accent : root.contentForeground
                fontFamily: root.contentFontFamily
                bordered: true
                focusable: true
                enabled: !root.calendarMutating
                onClicked: root.setEventMutationScope("instance")
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("editor.thisEvent")
                color: root.eventMutationScope === "instance" ? Commons.Color.accent : Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              PanelActionButton {
                iconText: "∞"
                tooltipText: strings.t("detail.s37")
                foreground: root.eventMutationScope === "series" ? Commons.Color.accent : root.contentForeground
                fontFamily: root.contentFontFamily
                bordered: true
                focusable: true
                enabled: !root.calendarMutating
                onClicked: root.setEventMutationScope("series")
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("editor.wholeSeries")
                color: root.eventMutationScope === "series" ? Commons.Color.accent : Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              visible: root.editingEvent && (!root.selectedAgendaEvent || root.selectedAgendaEvent.recurring)
              width: parent.width
              spacing: Style.space(5)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.selectedAgendaEvent ? strings.t("editor.schedule") : strings.t("editor.repeat")
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Repeater {
                model: root.eventRepeatOptions

                PanelActionButton {
                  required property var modelData
                  iconText: modelData.icon
                  tooltipText: modelData.value === "none"
                    ? (root.selectedAgendaEvent ? strings.t("detail.s38") : strings.t("detail.s39"))
                    : strings.t("dynamic.repeat").arg(modelData.label.toLowerCase())
                  foreground: root.eventRepeatMode === modelData.value ? Commons.Color.accent : root.contentForeground
                  fontFamily: root.contentFontFamily
                  bordered: true
                  focusable: true
                  enabled: !root.calendarCreating && !root.calendarMutating
                    && !root.eventTitleOnlyEditing
                    && (!root.selectedAgendaEvent || (root.eventMutationScope === "series" && modelData.value !== "none"))
                  onClicked: {
                    root.eventRepeatMode = modelData.value
                    if (modelData.value === "none") eventRepeatCountField.text = ""
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.eventRepeatLabel()
                color: (!root.selectedAgendaEvent || root.eventMutationScope === "series")
                  ? Commons.Color.accent : Qt.darker(root.contentForeground, 1.7)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                visible: root.eventRepeatMode !== "none"
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("editor.times")
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: eventRepeatCountField
                visible: root.eventRepeatMode !== "none"
                width: Style.space(55)
                height: Style.space(22)
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: "∞"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                verticalPadding: 0
                validator: IntValidator { bottom: 2; top: 999 }
                enabled: (!root.selectedAgendaEvent || root.eventMutationScope === "series")
                  && !root.eventTitleOnlyEditing
                Keys.onReturnPressed: root.saveLocalEvent()
                Keys.onEnterPressed: root.saveLocalEvent()
                Keys.onEscapePressed: root.cancelEditingEvent()
                onActiveFocusChanged: if (activeFocus) root.revealEditorControl(this)
              }
            }

            Row {
              visible: root.editingEvent
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: eventTitleField
                objectName: "eventTitleField"
                width: parent.width - eventAllDayButton.width - eventTimeField.width
                  - eventSaveButton.width - eventCancelButton.width
                  - (root.selectedAgendaEvent ? eventDeleteButton.width + Style.space(6) : 0) - Style.space(24)
                placeholderText: strings.t("editor.title")
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                Keys.onReturnPressed: root.saveLocalEvent()
                Keys.onEnterPressed: root.saveLocalEvent()
                Keys.onEscapePressed: root.cancelEditingEvent()
                onActiveFocusChanged: if (activeFocus) root.revealEditorControl(this)
              }

              PanelActionButton {
                id: eventAllDayButton
                objectName: "eventAllDayButton"
                iconText: root.eventAllDayEditing ? "󰃭" : "󰥔"
                tooltipText: root.eventAllDayEditing ? strings.t("detail.s40") : strings.t("detail.s41")
                foreground: root.eventAllDayEditing ? Commons.Color.accent : root.contentForeground
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                bordered: true
                focusable: true
                enabled: !root.calendarCreating && !root.calendarMutating
                  && !root.eventTitleOnlyEditing
                onClicked: {
                  root.eventAllDayEditing = !root.eventAllDayEditing
                  root.calendarSyncMessage = ""
                  if (root.eventAllDayEditing) {
                    eventTimeField.text = ""
                  } else {
                    Qt.callLater(function() { eventTimeField.forceActiveFocus() })
                  }
                }
              }

              TextField {
                id: eventTimeField
                objectName: "eventTimeField"
                width: Style.space(70)
                placeholderText: root.eventAllDayEditing ? strings.t("message.s11") : "HH:MM"
                foreground: root.contentForeground
                font.family: root.contentFontFamily
                enabled: !root.eventAllDayEditing && !root.calendarCreating && !root.calendarMutating
                  && !root.eventTitleOnlyEditing
                // Keep the friendly four-digit flow (0900 -> 09:00), but
                // never let a click or Tab leave the caret in a blank mask
                // slot. Input always resumes at the first missing digit.
                inputMask: "00:00"
                selectByMouse: false

                function nextEditablePosition() {
                  var value = String(text || "")
                  var slots = [0, 1, 3, 4]
                  for (var i = 0; i < slots.length; i++) {
                    var character = value.charAt(slots[i])
                    if (!/[0-9]/.test(character)) return slots[i]
                  }
                  return 5
                }

                function placeCursorAtNextDigit() {
                  if (!activeFocus) return
                  var next = nextEditablePosition()
                  if (cursorPosition !== next) cursorPosition = next
                }

                onActiveFocusChanged: {
                  if (activeFocus) {
                    Qt.callLater(placeCursorAtNextDigit)
                    root.revealEditorControl(this)
                  }
                }
                onCursorPositionChanged: Qt.callLater(placeCursorAtNextDigit)
                Keys.onReturnPressed: root.saveLocalEvent()
                Keys.onEnterPressed: root.saveLocalEvent()
                Keys.onEscapePressed: root.cancelEditingEvent()
              }

              PanelActionButton {
                id: eventSaveButton
                objectName: "eventSaveButton"
                iconText: "󰄬"
                tooltipText: root.selectedAgendaEvent ? strings.t("message.s21") : strings.t("message.s22")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                focusable: true
                enabled: !root.calendarCreating && !root.calendarMutating
                onClicked: root.saveLocalEvent()
                onActiveFocusChanged: if (activeFocus) root.revealEditorControl(this)
              }

              PanelActionButton {
                id: eventDeleteButton
                objectName: "eventDeleteButton"
                visible: !!root.selectedAgendaEvent
                iconText: "󰆴"
                tooltipText: root.deleteTooltipText()
                foreground: root.calendarDeleteArmed ? Commons.Color.urgent : root.contentForeground
                hoverColor: Commons.Color.urgent
                fontFamily: root.contentFontFamily
                focusable: true
                enabled: !root.calendarCreating && !root.calendarMutating
                onClicked: root.deleteSelectedEvent()
                onActiveFocusChanged: if (activeFocus) root.revealEditorControl(this)
              }

              PanelActionButton {
                id: eventCancelButton
                iconText: "󰅖"
                tooltipText: strings.t("editor.cancel")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                focusable: true
                enabled: !root.calendarCreating && !root.calendarMutating
                onClicked: root.cancelEditingEvent()
              }
            }

            Row {
              visible: root.editingEvent && !root.eventTitleOnlyEditing
              width: parent.width
              spacing: Style.space(8)

              Column {
                visible: !root.eventAllDayEditing
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("editor.duration")
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Dropdown {
                  id: eventDurationChoice
                  objectName: "eventDurationChoice"
                  property bool edited: false
                  width: parent.width
                  rowHeight: Style.space(28)
                  popupRowHeight: Style.space(26)
                  showLabel: false
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  options: root.durationOptions
                  onChanged: function(value) {
                    edited = true
                    root.calendarSyncMessage = ""
                    if (value === "custom") Qt.callLater(function() { eventDurationField.forceActiveFocus(); eventDurationField.selectAll() })
                  }
                  onPopupOpenChanged: root.revealDropdown(this)
                }

                EventMinutesField {
                  id: eventDurationField
                  objectName: "eventDurationField"
                  visible: eventDurationChoice.value === "custom"
                  maximum: CalendarModel.MAX_DURATION_MINUTES
                  onTextEdited: eventDurationChoice.edited = true
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("editor.reminder")
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Dropdown {
                  id: eventReminderChoice
                  objectName: "eventReminderChoice"
                  property bool edited: false
                  width: parent.width
                  rowHeight: Style.space(28)
                  popupRowHeight: Style.space(26)
                  showLabel: false
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  options: root.reminderOptions
                  onChanged: function(value) {
                    edited = true
                    root.calendarSyncMessage = ""
                    if (value === "custom") Qt.callLater(function() { eventReminderField.forceActiveFocus(); eventReminderField.selectAll() })
                  }
                  onPopupOpenChanged: root.revealDropdown(this)
                }

                EventMinutesField {
                  id: eventReminderField
                  objectName: "eventReminderField"
                  visible: eventReminderChoice.value === "custom"
                  maximum: CalendarModel.MAX_REMINDER_MINUTES
                  onTextEdited: eventReminderChoice.edited = true
                }
              }
            }

            Controls.TextArea {
              id: eventDescriptionField
              objectName: "eventDescriptionField"
              visible: root.editingEvent
              width: parent.width
              height: visible ? Style.space(52) : 0
              placeholderText: root.eventTitleOnlyEditing
                ? strings.t("editor.birthdayDescription")
                : strings.t("editor.description")
              color: root.contentForeground
              placeholderTextColor: Qt.darker(root.contentForeground, 1.6)
              selectionColor: Style.selectionFillFor(root.contentForeground, Commons.Color.accent)
              selectedTextColor: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: TextEdit.Wrap
              textFormat: TextEdit.PlainText
              leftPadding: Style.spacing.controlPaddingX
              rightPadding: Style.spacing.controlPaddingX
              topPadding: Style.spacing.inputPaddingY
              bottomPadding: Style.spacing.inputPaddingY
              enabled: !root.calendarCreating && !root.calendarMutating
                && !root.eventTitleOnlyEditing
              background: BorderSurface {
                color: Style.controlFill(eventDescriptionField.activeFocus,
                  eventDescriptionField.hovered, root.contentForeground, Commons.Color.accent)
                borderSpec: Border.controlSpec(eventDescriptionField.activeFocus ? "focus"
                  : (eventDescriptionField.hovered ? "hover-cursor" : "normal"),
                  root.contentForeground, Commons.Color.accent)
                radius: Style.cornerRadius
              }
              Keys.onEscapePressed: root.cancelEditingEvent()
              onActiveFocusChanged: if (activeFocus) root.revealEditorControl(this)
              Keys.onPressed: function(event) {
                if ((event.modifiers & Qt.ControlModifier)
                    && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                  root.saveLocalEvent()
                  event.accepted = true
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.calendarLoading && root.calendarError !== ""
              width: parent.width
              wrapMode: Text.Wrap
              text: root.calendarError
              color: Qt.darker(root.contentForeground, 1.4)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.editingEvent && !root.calendarLoading && root.calendarError === "" && root.agendaEvents.length === 0
              text: strings.t("agenda.empty")
              color: Qt.darker(root.contentForeground, 1.7)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              // Repeater delegates are inserted into this Column rather than
              // remaining visual children of the Repeater. Emptying the model
              // is therefore the reliable way to remove agenda rows while the
              // event form is active.
              model: root.editingEvent ? [] : root.agendaEvents

              Column {
                id: agendaEvent
                required property var modelData
                width: parent.width
                spacing: Style.space(3)
                property string eventKey: root.eventKeyFor(modelData)
                property bool isNextEvent: root.nextTimedEventKey !== ""
                  && agendaEvent.eventKey === root.nextTimedEventKey
                property var meetingLinks: CalendarModel.eventMeetingLinks(modelData)
                property bool hasDescription: String(modelData.description || "").trim() !== ""
                property bool descriptionExpanded: hasDescription
                  && root.expandedAgendaInstanceId === eventKey

                // The next timed event of the day gets the Style "selected"
                // treatment — the persistent current state — so the eye
                // lands on what comes next without a hover-style wash.
                Rectangle {
                  width: parent.width
                  height: Math.max(Style.space(30), agendaEventRow.implicitHeight + Style.space(8))
                  radius: Style.cornerRadius
                  color: agendaEvent.isNextEvent
                    ? Style.selectedFillFor(root.contentForeground, Commons.Color.accent)
                    : "transparent"
                  border.width: agendaEvent.isNextEvent ? Style.spacing.hairline : 0
                  border.color: Style.selectedBorderFor(root.contentForeground, Commons.Color.accent)

                  Row {
                    id: agendaEventRow
                    // Inset the row from the highlight frame so the border
                    // clears the calendar indicator and action buttons.
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(5)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(5)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(7)

                    Rectangle {
                      width: Style.spacing.hairline * 2
                      height: Math.max(Style.space(22), eventTitle.implicitHeight)
                      radius: width / 2
                      color: root.displayCalendarColor(modelData)
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: Style.space(58)
                      text: root.eventTimeLabel(modelData)
                      color: Qt.darker(root.contentForeground, 1.5)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Item {
                      width: parent.width - Style.space(65) - Style.spacing.hairline * 2 - Style.space(21)
                        - (joinAgendaButton.visible ? joinAgendaButton.width + Style.space(7) : 0)
                        - (modelData.calendar_read_only ? 0 : editAgendaButton.width)
                      height: Math.max(eventTitle.implicitHeight, Style.space(22))

                      Text {
                        textFormat: Text.PlainText
                        id: eventTitle
                        anchors.left: parent.left
                        anchors.right: descriptionChevron.visible ? descriptionChevron.left : parent.right
                        anchors.rightMargin: descriptionChevron.visible ? Style.space(5) : 0
                        elide: Text.ElideRight
                        text: CalendarModel.boundedText(modelData.title, 4096) || strings.t("message.s10")
                        color: agendaEvent.isNextEvent
                          ? Style.selectedStateColor(root.contentForeground, Commons.Color.accent)
                          : root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: agendaEvent.isNextEvent
                      }

                      Text {
                        textFormat: Text.PlainText
                        id: descriptionChevron
                        visible: agendaEvent.hasDescription
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: agendaEvent.descriptionExpanded ? "⌃" : "⌄"
                        color: Qt.darker(root.contentForeground, 1.35)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      MouseArea {
                        anchors.fill: parent
                        enabled: agendaEvent.hasDescription
                        hoverEnabled: enabled
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.expandedAgendaInstanceId = agendaEvent.descriptionExpanded
                          ? "" : agendaEvent.eventKey
                      }
                    }

                    Button {
                      id: joinAgendaButton
                      visible: agendaEvent.meetingLinks.length > 0
                      text: strings.t("agenda.join")
                      fontSize: Style.font.caption
                      horizontalPadding: Style.space(6)
                      verticalPadding: Style.space(3)
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      tooltipText: agendaEvent.meetingLinks.length > 0
                        ? CalendarModel.textForMarkupSink(agendaEvent.meetingLinks[0], 256) : ""
                      bordered: true
                      onClicked: {
                        Qt.openUrlExternally(agendaEvent.meetingLinks[0])
                        root.close()
                      }
                    }

                    PanelActionButton {
                      id: editAgendaButton
                      visible: !modelData.calendar_read_only && !modelData.event_read_only
                      iconText: "󰏫"
                      tooltipText: modelData.recurring ? strings.t("detail.s42") : strings.t("message.s23")
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      enabled: !root.calendarCreating && !root.calendarMutating
                      onClicked: root.startEditingEvent(modelData)
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  visible: agendaEvent.descriptionExpanded
                  // Indent to the title column: the row's 5px frame inset
                  // plus indicator, gap, and time column.
                  width: parent.width - Style.space(79)
                  x: Style.space(79)
                  wrapMode: Text.Wrap
                  text: CalendarModel.boundedText(modelData.description, 20000)
                  color: Qt.darker(root.contentForeground, 1.35)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

          }

          // All operation progress and transient feedback uses one predictable
          // location below the agenda. Keeping it outside agendaSection also
          // leaves the spinner active while the agenda controls are disabled.
          Row {
            id: calendarFeedbackRow
            visible: root.calendarProgressVisible || root.calendarFeedback !== ""
            width: gridColumn.width
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: statusSpinner.visible ? Style.space(6) : 0

            Text {
              textFormat: Text.PlainText
              id: statusSpinner
              visible: root.calendarProgressVisible
              anchors.verticalCenter: parent.verticalCenter
              text: "󰄉"
              color: Commons.Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              transformOrigin: Item.Center
              rotation: 0
              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: Style.duration(800)
                loops: Animation.Infinite
                running: root.calendarProgressVisible && !Style.reduceMotion
              }
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - (statusSpinner.visible ? statusSpinner.implicitWidth + parent.spacing : 0)
              wrapMode: Text.Wrap
              text: root.calendarProgressVisible ? root.calendarProgressLabel : root.calendarFeedback
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      BorderSurface {
        id: settingsCard
        visible: root.settingsOpen
        z: 20
        x: root.settingsCardOnRight
          ? keyCatcher.width + panel.padding + Border.right(panel.borderSpec) + root.settingsCardGap
          : root.settingsCardOnLeft
            ? -panel.padding - Border.left(panel.borderSpec) - width - root.settingsCardGap
            : keyCatcher.width - width
        y: {
          var natural = -panel.padding - Border.top(panel.borderSpec)
          if (panel.screenH <= 0) return natural
          var top = root.calendarPanelPosition === "screen-center"
            ? (root.calendarFrozenTop >= 0 ? root.calendarFrozenTop : root.calendarCenteredTop())
            : panel.cardOrigin.y
          var bounds = root.calendarVerticalBounds()
          var fittedTop = Math.max(bounds.top, Math.min(top, bounds.bottom - height))
          return natural + fittedTop - top
        }
        width: root.settingsCardWidth
        height: {
          var desired = settingsColumn.implicitHeight + contentTopInset + contentBottomInset
          var bounds = root.calendarVerticalBounds()
          return panel.screenH > 0 ? Math.min(desired, bounds.bottom - bounds.top) : desired
        }
        color: Commons.Color.popups.background
        borderSpec: panel.borderSpec
        padding: Style.spacing.popupPadding
        radius: Style.cornerRadius

        Keys.onEscapePressed: function(event) {
          root.toggleSettings()
          event.accepted = true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
        }

        Flickable {
          id: calendarSettingsScroll
          objectName: "calendarSettingsScroll"
          x: settingsCard.contentLeftInset
          y: settingsCard.contentTopInset
          width: settingsCard.width - settingsCard.contentLeftInset - settingsCard.contentRightInset
          height: settingsCard.height - settingsCard.contentTopInset - settingsCard.contentBottomInset
          contentWidth: width
          contentHeight: settingsColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          clip: true
          interactive: contentHeight > height
          Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

          Column {
            id: settingsColumn
            width: calendarSettingsScroll.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              height: Math.max(settingsTitle.implicitHeight, settingsCloseButton.implicitHeight)

              Text {
                textFormat: Text.PlainText
                id: settingsTitle
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("settings.heading")
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                font.letterSpacing: 1
              }

              PanelActionButton {
                id: settingsCloseButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅖"
                tooltipText: strings.t("settings.close")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                focusable: true
                onClicked: root.toggleSettings()
              }
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: 0.12
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("settings.position")
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Row {
              spacing: Style.spacing.md

              SettingsChoiceButton {
                optionValue: "screen-center"
                currentValue: root.calendarPanelPosition
                text: strings.t("settings.center")
                tooltipText: strings.t("detail.s43")
                foreground: root.contentForeground
                background: Commons.Color.popups.background
                accent: Commons.Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                onChosen: function(value) { root.setCalendarPanelPosition(value) }
              }

              SettingsChoiceButton {
                optionValue: "original"
                currentValue: root.calendarPanelPosition
                text: strings.t("settings.original")
                tooltipText: strings.t("detail.s44")
                foreground: root.contentForeground
                background: Commons.Color.popups.background
                accent: Commons.Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                onChosen: function(value) { root.setCalendarPanelPosition(value) }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.Wrap
              text: root.calendarPanelPosition === "screen-center"
                ? strings.t("settings.centerDescription")
                : strings.t("settings.originalDescription")
              color: Qt.darker(root.contentForeground, 1.65)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: 0.12
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("settings.oauth")
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.Wrap
              text: root.authStatusLoading
                ? strings.t("message.s12")
                : root.authStatusError !== "" ? root.authStatusError
                : root.authMode === "connected" ? strings.t("settings.connected") : strings.t("message.s13")
              color: Qt.darker(root.contentForeground, 1.35)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              text: root.authMode === "connected" ? strings.t("settings.reconnect") : strings.t("settings.connect")
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              bordered: true
              focusable: true
              enabled: !root.authStatusLoading
              onClicked: root.runCalendarSetup()
            }

            Toggle {
              objectName: "calendarAutoPushToggle"
              width: parent.width
              label: strings.t("settings.autoPush")
              description: strings.t("settings.autoPushDescription")
              checked: root.calendarAutoPush
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              titleSize: Style.font.bodySmall
              onClicked: root.persistSettings({ calendarAutoPush: !root.calendarAutoPush })
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: 0.12
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("settings.colors")
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Row {
              spacing: Style.spacing.md

              SettingsChoiceButton {
                optionValue: "google"
                currentValue: root.calendarColorMode
                text: "GOOGLE"
                tooltipText: strings.t("detail.s47")
                foreground: root.contentForeground
                background: Commons.Color.popups.background
                accent: Commons.Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                onChosen: function(value) { root.setCalendarColorMode(value) }
              }

              SettingsChoiceButton {
                optionValue: "theme"
                currentValue: root.calendarColorMode
                text: strings.t("settings.theme")
                tooltipText: strings.t("detail.s48")
                foreground: root.contentForeground
                background: Commons.Color.popups.background
                accent: Commons.Color.accent
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                onChosen: function(value) { root.setCalendarColorMode(value) }
              }
            }

            Row {
              visible: root.calendarColorMode === "theme"
              spacing: Style.space(7)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(8)
                height: width
                radius: width / 2
                color: root.themeCalendarPrimary
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(8)
                height: width
                radius: width / 2
                color: root.themeCalendarSecondary
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("settings.followsTheme")
                color: Qt.darker(root.contentForeground, 1.65)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.contentForeground
              opacity: 0.12
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: strings.t("settings.removeHeading")
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.Wrap
              text: strings.t("settings.removeDescription")
              color: Qt.darker(root.contentForeground, 1.65)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              text: strings.t("settings.remove")
              tooltipText: strings.t("settings.removeTooltip")
              foreground: root.contentForeground
              background: Commons.Color.popups.background
              accent: Commons.Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(6)
              verticalPadding: Style.space(2)
              bordered: true
              focusable: true
              // Match the settings choices: keep the fill stable on hover and
              // leave only the immediate hover border feedback.
              color: background
              onClicked: root.runPluginUninstall()
            }

            Item {
              width: parent.width
              height: settingsVersionLabel.implicitHeight

              Text {
                textFormat: Text.PlainText
                id: settingsVersionLabel
                anchors.right: parent.right
                text: "v" + root.pluginVersion
                color: Qt.darker(root.contentForeground, 1.8)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
