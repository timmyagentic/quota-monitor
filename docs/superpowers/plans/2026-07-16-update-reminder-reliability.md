# Update Reminder Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a discovered Sparkle update visible across relaunches, expose it on the native status item, remind once after 24 hours and then every 3 days without stealing focus, and make Later/Skip/install semantics match Sparkle.

**Architecture:** Persist a version-scoped `PendingUpdateSnapshot` in the active QA/production `UserDefaults` suite while keeping Sparkle reply closures strictly in memory. A pure policy decides when a reminder is due, a small coordinator converts due reminders into a temporary native status-item emphasis, and `CustomUserDriver` suppresses automatic rediscovery while the same version is snoozed. App Store builds use an ephemeral empty state.

**Tech Stack:** Swift 6 strict concurrency, Observation, AppKit status items, Sparkle 2.9.2, Swift Testing, SwiftPM, QuotaMonitor Computer QA.

## Global Constraints

- Work only in `/Volumes/SamsungDisk/Code/.worktrees/quota-monitor-update-notification-version-distribution-audit` on `codex/update-notification-version-distribution-audit`; never edit the primary checkout or `main`.
- Persist Sparkle `versionString` separately from user-facing `displayVersionString`; compare the internal version against `CFBundleVersion`.
- Persist data only, never a Sparkle reply closure or window state.
- First Later reminder is due after exactly 86,400 seconds; recurring reminders are due after exactly 259,200 seconds.
- A due reminder may emphasize/pulse the native status item but must not activate the app, open a window, or request notification permission.
- A manual Check Now may always present the update; an automatic rediscovery of the same snoozed version must reply `.dismiss` without reopening the window.
- Skip exists only during `.updateAvailable`; `.readyToInstall` exposes only Later and Install & Relaunch.
- Transient updater errors preserve the pending snapshot. Clear it only after install/current-version validation, explicit Skip, or definitive no-update.
- App Store and Local QA isolation must never restore or write production update-reminder state.
- Use test-first RED/GREEN cycles, update both changelogs, run static QA, and complete real-data shadow Computer QA before publication.

---

## File Structure

**New:**

- `QuotaMonitor/Core/Updater/UpdateReminderPolicy.swift` — constants and pure due-date decisions.
- `QuotaMonitor/Core/Updater/UpdateReminderCoordinator.swift` — cancel-safe wall-clock scheduling and presentation callback.
- `Tests/QuotaMonitorTests/UpdateReminderPolicyTests.swift` — cadence boundary coverage.
- `Tests/QuotaMonitorTests/UpdateReminderCoordinatorTests.swift` — restart, cancel, and consume-once scheduling coverage.

**Modified:**

- `QuotaMonitor/Core/Updater/PersistentUpdateAvailability.swift` — Codable persisted snapshot and version-scoped state transitions.
- `QuotaMonitor/Core/Updater/UpdaterController.swift` — production/QA defaults injection and coordinator ownership.
- `QuotaMonitor/Core/Updater/CustomUserDriver.swift` — internal/display version discovery and correct Sparkle replies.
- `QuotaMonitor/Core/Updater/UpdateWindowState.swift` and `UpdateWindowView.swift` — phase-specific action availability.
- `QuotaMonitor/App/AppDelegate.swift` and `StatusItemController.swift` — coordinator wiring and native marker rendering.
- `QuotaMonitor/Core/Localization/L10n.swift` — marker accessibility and corrected ready-state copy.
- Focused update/status tests plus both changelogs.

## Interfaces

```swift
struct PendingUpdateSnapshot: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case available, readyToInstall }
    let internalVersion: String
    let displayVersion: String
    var phase: Phase
    let firstSeenAt: Date
    var nextReminderAt: Date?
    var deliveredReminderCount: Int
}
```

```swift
enum UpdateReminderPolicy {
    static let initialDelay: TimeInterval = 86_400
    static let recurringDelay: TimeInterval = 259_200
    static func nextDate(after now: Date, deliveredCount: Int) -> Date
    static func isDue(_ snapshot: PendingUpdateSnapshot, at now: Date) -> Bool
}
```

```swift
@MainActor
@Observable
final class PersistentUpdateAvailability {
    enum DiscoveryPresentation: Equatable { case presentWindow, dismissSilently }
    private(set) var snapshot: PendingUpdateSnapshot?
    init(defaults: UserDefaults, currentInternalVersion: String, persistenceEnabled: Bool = true)
    func recordDiscovery(internalVersion: String, displayVersion: String,
                         userInitiated: Bool, now: Date = Date()) -> DiscoveryPresentation
    func markLater(now: Date = Date())
    func markReadyToInstall()
    func consumeDueReminder(now: Date = Date()) -> String?
    func markSkipped()
    func clear()
}
```

```swift
@MainActor
final class UpdateReminderCoordinator {
    typealias Present = @MainActor (_ displayVersion: String) -> Void
    init(availability: PersistentUpdateAvailability,
         now: @escaping @MainActor () -> Date = Date.init,
         sleep: @escaping @Sendable (Duration) async throws -> Void = Task.sleep,
         present: @escaping Present)
    func start()
    func reschedule()
    func stop()
}
```

`UpdateReminderCoordinator` tracks `availability.snapshot?.nextReminderAt` with Observation and rearms after every mutation. `StatusItemController` exposes `func pulseUpdateMarker(version: String)` as the only presentation surface.

---

### Task 1: Persist and restore version-scoped update state

**Files:**

- Modify: `QuotaMonitor/Core/Updater/PersistentUpdateAvailability.swift`
- Modify: `Tests/QuotaMonitorTests/PersistentUpdateAvailabilityTests.swift`

- [ ] **Step 1: Write failing persistence tests**

Use an isolated suite and assert a fresh object restores the same snapshot, a corrupt payload self-clears, a newer discovery resets reminder count, and a current build at or above the stored internal version removes it:

```swift
let defaults = UserDefaults(suiteName: "PersistentUpdateAvailabilityTests.\(#function)")!
defaults.removePersistentDomain(forName: "PersistentUpdateAvailabilityTests.\(#function)")
let first = PersistentUpdateAvailability(defaults: defaults, currentInternalVersion: "40")
#expect(first.recordDiscovery(internalVersion: "41", displayVersion: "0.2.41",
                              userInitiated: false, now: .init(timeIntervalSince1970: 100)) == .presentWindow)
let restored = PersistentUpdateAvailability(defaults: defaults, currentInternalVersion: "40")
#expect(restored.version == "0.2.41")
#expect(restored.snapshot?.internalVersion == "41")
```

- [ ] **Step 2: Confirm RED**

Run `swift test --disable-keychain --filter PersistentUpdateAvailabilityTests`.
Expected: compile failures because the injected initializer and snapshot do not exist.

- [ ] **Step 3: Implement minimal Codable persistence**

Store one JSON `Data` value under `app.pendingUpdateSnapshot.v1`. Restore only when persistence is enabled and `currentInternalVersion.compare(snapshot.internalVersion, options: .numeric) == .orderedAscending`. Invalid data and installed/current versions call `clear()`.

- [ ] **Step 4: Add transition tests and implementation**

Prove `markSkipped`, `clear`, and a replacement version remove/reset the expected fields. `markReadyToInstall` persists only `.readyToInstall`; the live primary action may return to `.install` after relaunch until Sparkle rehydrates the installer.

- [ ] **Step 5: Confirm GREEN and commit**

Run the suite and commit Task 1 files with `Persist pending update state across relaunches`.

### Task 2: Encode the 24-hour and three-day reminder policy

**Files:**

- Create: `QuotaMonitor/Core/Updater/UpdateReminderPolicy.swift`
- Create: `Tests/QuotaMonitorTests/UpdateReminderPolicyTests.swift`
- Modify: `QuotaMonitor/Core/Updater/PersistentUpdateAvailability.swift`

- [ ] **Step 1: Write failing boundary tests**

```swift
let now = Date(timeIntervalSince1970: 1_000)
#expect(UpdateReminderPolicy.nextDate(after: now, deliveredCount: 0)
        == now.addingTimeInterval(86_400))
#expect(UpdateReminderPolicy.nextDate(after: now, deliveredCount: 1)
        == now.addingTimeInterval(259_200))
```

Test one second before, exactly at, and after each boundary. Verify `consumeDueReminder` returns nil before due, returns the display version once at due, increments the count, and atomically advances `nextReminderAt` by three days.

- [ ] **Step 2: Confirm RED**

Run `swift test --disable-keychain --filter UpdateReminderPolicyTests`.
Expected: compile failure because policy/consume APIs do not exist.

- [ ] **Step 3: Implement the pure policy and state transitions**

`markLater` schedules 24 hours only when no reminder has been delivered; otherwise it schedules three days. `consumeDueReminder` must persist the next date before returning a version so a crash or duplicate wake cannot double-present.

- [ ] **Step 4: Confirm GREEN and commit**

Run policy plus persistence suites and commit with `Schedule gentle recurring update reminders`.

### Task 3: Make Sparkle discovery and action semantics exact

**Files:**

- Modify: `QuotaMonitor/Core/Updater/CustomUserDriver.swift`
- Modify: `QuotaMonitor/Core/Updater/UpdateWindowState.swift`
- Modify: `QuotaMonitor/Core/Updater/UpdateWindowView.swift`
- Modify: `Tests/QuotaMonitorTests/UpdateWindowReplyHandlerTests.swift`
- Modify: `Tests/QuotaMonitorTests/CustomUserDriverBadgeSelfHealTests.swift`

- [ ] **Step 1: Write failing action-state tests**

Add behavior assertions that update-available exposes install/skip/later, ready-to-install exposes only install/later, and consuming any reply clears sibling handlers. Add a structural guard proving the ready callback never assigns `state.onSkip`.

- [ ] **Step 2: Confirm RED**

Run `swift test --disable-keychain --filter 'UpdateWindowReplyHandlerTests|CustomUserDriverBadgeSelfHealTests'`.
Expected: ready-state skip assertions fail.

- [ ] **Step 3: Record internal and display versions**

In `showUpdateFound`, call:

```swift
let presentation = updateAvailability.recordDiscovery(
    internalVersion: appcastItem.versionString,
    displayVersion: appcastItem.displayVersionString,
    userInitiated: state.userInitiated)
```

If it returns `.dismissSilently`, consume the reply once with `.dismiss` and do not show/reset the window. Manual checks always return `.presentWindow`.

- [ ] **Step 4: Separate ready-to-install actions**

Remove the ready-stage `onSkip` closure and hide the Skip button whenever `phase == .readyToInstall`. Later calls `markLater` and replies `.dismiss`; initial Skip calls `markSkipped` and replies `.skip`.

- [ ] **Step 5: Confirm GREEN and commit**

Run the focused suites and commit with `Align update actions with Sparkle semantics`.

### Task 4: Add a native status-item update marker

**Files:**

- Modify: `QuotaMonitor/App/StatusItemController.swift`
- Modify: `QuotaMonitor/Core/Localization/L10n.swift`
- Modify: `Tests/QuotaMonitorTests/MenuBarTitleBuilderTests.swift`
- Modify: `Tests/QuotaMonitorTests/MainWindowLayoutTests.swift`

- [ ] **Step 1: Write failing rendering tests**

Extract a testable helper that decorates the existing title without changing it when no update exists:

```swift
let original = NSAttributedString(string: "5h 42% · 7d 68%")
#expect(StatusItemUpdateMarker.title(base: original, version: nil).string == original.string)
#expect(StatusItemUpdateMarker.title(base: original, version: "0.2.41").string.hasSuffix(" ↓"))
```

Also assert the fallback gauge remains present when the marker is visible and accessibility/tooltip copy contains the display version.

- [ ] **Step 2: Confirm RED**

Run `swift test --disable-keychain --filter 'MenuBarTitleBuilderTests|MainWindowLayoutTests'`.
Expected: helper/marker assertions fail.

- [ ] **Step 3: Implement marker rendering**

Make `renderLabel()` read `updater.updateAvailability.version`, append one short orange update symbol to text rows, retain the gauge for empty rows, and set a localized tooltip/accessibility label. Keep the no-update bytes and quota ordering unchanged.

- [ ] **Step 4: Confirm GREEN and commit**

Run the focused suites and commit with `Show pending updates on the native status item`.

### Task 5: Schedule due reminders without stealing focus

**Files:**

- Create: `QuotaMonitor/Core/Updater/UpdateReminderCoordinator.swift`
- Create: `Tests/QuotaMonitorTests/UpdateReminderCoordinatorTests.swift`
- Modify: `QuotaMonitor/Core/Updater/UpdaterController.swift`
- Modify: `QuotaMonitor/App/AppDelegate.swift`
- Modify: `QuotaMonitor/App/StatusItemController.swift`

- [ ] **Step 1: Write failing coordinator tests**

Use a controlled clock/sleeper and presenter to prove startup immediately consumes one overdue reminder, future reminders schedule once, `reschedule()` cancels stale tasks, and `stop()` prevents presentation. A present callback receives only `displayVersion`.

- [ ] **Step 2: Confirm RED**

Run `swift test --disable-keychain --filter UpdateReminderCoordinatorTests`.
Expected: compile failure because the coordinator does not exist.

- [ ] **Step 3: Implement cancel-safe scheduling**

The coordinator reevaluates wall-clock `Date` after every wake. `UpdaterController` owns it and calls `reschedule()` after discovery/Later/skip/clear. The production presenter asks `StatusItemController` to pulse/emphasize its marker for eight seconds without opening the popover or activating `NSApp`.

- [ ] **Step 4: Preserve QA and App Store boundaries**

Construct availability with `LocalQAEnvironment.userDefaults() ?? .standard`; set `persistenceEnabled` false and omit the coordinator for App Store builds. Local QA writes only to its isolated suite and the presenter is disabled when the QA boundary forbids external UI prompting.

- [ ] **Step 5: Confirm GREEN and commit**

Run coordinator, updater, app lifecycle, and status suites; commit with `Deliver gentle recurring update reminders`.

### Task 6: Document and verify the complete behavior

**Files:**

- Modify: `CHANGELOG.md`
- Modify: `CHANGELOG.zh-Hans.md`

- [ ] **Step 1: Add bilingual release notes**

English Summary: `Update reminders now survive relaunches, remain visible in the menu bar, and return gently instead of disappearing after Later.`

Chinese Summary: `更新提醒现在会跨重启保留、常驻显示在菜单栏，并在选择“稍后”后温和地再次提醒，不再悄悄消失。`

Document the 24-hour/three-day cadence and the corrected ready-to-install action semantics under Changed/Fixed.

- [ ] **Step 2: Run focused and full static gates**

```bash
swift test --disable-keychain --filter 'PersistentUpdateAvailabilityTests|UpdateReminderPolicyTests|UpdateReminderCoordinatorTests|UpdateWindowReplyHandlerTests|MenuBarTitleBuilderTests|MainWindowLayoutTests'
./qa/run-static.sh
```

- [ ] **Step 3: Run visible Computer QA**

Use `./qa/prepare-computer-use-real-data.sh`, target the exact app path from `computer-use-qa.md`, verify the normal status title, restored marker, popover badge, Settings update section, and no focus-stealing reminder window. Check artifacts and run the printed cleanup script.

- [ ] **Step 4: Commit verification/docs**

Commit remaining files with `Document reliable update reminders`.
