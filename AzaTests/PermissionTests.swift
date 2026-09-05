import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreLocation
import XCTest

@MainActor
final class PermissionTests: XCTestCase {
    func testModalWindowReceivesClicksInsteadOfSettingsBehindIt() async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        try XCTSkipIf(session?["CGSSessionScreenIsLocked"] as? Bool == true,
                      "WindowServer hides application windows behind the locked screen")
        _ = NSApplication.shared
        let frame = NSRect(x: 100, y: 100, width: 200, height: 120)
        let settings = NSWindow(contentRect: frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        let modal = NSWindow(contentRect: frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
        for window in [settings, modal] {
            window.isReleasedWhenClosed = false
            window.backgroundColor = .windowBackgroundColor
        }
        defer { modal.close(); settings.close() }
        modal.level = .modalPanel
        let point = NSPoint(x: frame.midX, y: frame.midY)
        settings.orderFrontRegardless()
        modal.orderFrontRegardless()
        // WindowServer применяет порядок окон асинхронно.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(settings.receivesMouse(at: point))
        XCTAssertTrue(modal.receivesMouse(at: point), "target=\(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)), modal=\(modal.windowNumber), settings=\(settings.windowNumber), visible=\(modal.isVisible)")
        modal.ignoresMouseEvents = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(settings.receivesMouse(at: point), "target=\(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)), settings=\(settings.windowNumber)")
        settings.orderOut(nil)
        XCTAssertFalse(settings.receivesMouse(at: point))
    }

    func testSmallCompressedImageCannotRequestHugeDecodedAllocation() throws {
        let tiny = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2,
            pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        let png = try XCTUnwrap(tiny.representation(using: .png, properties: [:]))
        XCTAssertTrue(PasteboardMonitor.imageIsSafeToDecode(png))
        // Валидный IHDR 100000×100000: размер файла всего 68 байт,
        // потенциальный RGBA-буфер — 40 ГБ. До декодирования пикселей не доходим.
        let oversized = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgABhqAAAYagCAYAAACoUgvIAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="))
        XCTAssertFalse(PasteboardMonitor.imageIsSafeToDecode(oversized))
        XCTAssertFalse(PasteboardMonitor.imageIsSafeToDecode(Data("not an image".utf8)))
    }

    func testLateNotificationPermissionDoesNotUndoTurningNotificationsOff() async {
        let key = "PrayerNotificationsEnabled"
        let oldValue = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(oldValue, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        let notifications = NotificationsStub()
        let prayer = PrayerStore(notifications: notifications)
        var reply: CheckedContinuation<Bool, Never>?
        let started = expectation(description: "notification permission")
        notifications.authorize = {
            await withCheckedContinuation {
                reply = $0
                started.fulfill()
            }
        }
        let task = Task { await prayer.setNotifications(enabled: true) }
        await fulfillment(of: [started], timeout: 1)
        await prayer.setNotifications(enabled: false)
        reply?.resume(returning: true)
        await task.value
        XCTAssertFalse(prayer.notificationsEnabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
        await prayer.shutdownForCleanup()
    }

    func testMicrophoneRequestDoesNotRecordOrRepeatWhileWaiting() async {
        var reply: CheckedContinuation<Bool, Never>?
        var requests = 0
        let started = expectation(description: "permission request")
        let dictation = DictationController(clipboardStore: { nil },
            microphoneAuthorization: { .notDetermined },
            requestMicrophoneAuthorization: {
                requests += 1
                return await withCheckedContinuation {
                    reply = $0
                    started.fulfill()
                }
            })
        let task = Task { await dictation.requestMicrophoneAccess() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(dictation.isRequestingMicrophone)
        XCTAssertEqual(dictation.state, .idle)
        dictation.startLatchedFromUI()
        await dictation.requestMicrophoneAccess()
        XCTAssertEqual(requests, 1)
        XCTAssertNil(dictation.recordingStartedAt)
        XCTAssertFalse(dictation.isLatched)
        reply?.resume(returning: true)
        await task.value
        XCTAssertFalse(dictation.isRequestingMicrophone)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertNil(dictation.loadedProfile)
        XCTAssertTrue(dictation.status.contains("ещё раз"))
    }

    func testMicrophoneDenialAndCancelledRequestStayIdle() async {
        let denied = DictationController(clipboardStore: { nil },
            microphoneAuthorization: { .notDetermined },
            requestMicrophoneAuthorization: { false })
        await denied.requestMicrophoneAccess()
        XCTAssertEqual(denied.state, .idle)
        XCTAssertTrue(denied.status.contains("Нет доступа"))
        var reply: CheckedContinuation<Bool, Never>?
        let started = expectation(description: "permission request")
        let stopped = DictationController(clipboardStore: { nil },
            microphoneAuthorization: { .notDetermined },
            requestMicrophoneAuthorization: {
                await withCheckedContinuation {
                    reply = $0
                    started.fulfill()
                }
            })
        let task = Task { await stopped.requestMicrophoneAccess() }
        await fulfillment(of: [started], timeout: 1)
        stopped.stop()
        reply?.resume(returning: true)
        await task.value
        XCTAssertEqual(stopped.state, .idle)
        XCTAssertNil(stopped.loadedProfile)
        XCTAssertFalse(stopped.isRequestingMicrophone)
    }

    func testLocationSeparatesSystemDisabledAndAppDenial() async {
        let manager = LocationManagerStub()
        manager.authorization = .denied
        let disabled = CityLocator(manager: manager, servicesEnabled: { false })
        let disabledResult = await disabled.locate()
        XCTAssertNil(disabledResult)
        let denied = CityLocator(manager: manager, servicesEnabled: { true })
        let deniedResult = await denied.locate()
        XCTAssertNil(deniedResult)
        XCTAssertNotEqual(disabled.state, denied.state)
        manager.authorization = .restricted
        let restricted = CityLocator(manager: manager, servicesEnabled: { true })
        let restrictedResult = await restricted.locate()
        XCTAssertNil(restrictedResult)
        XCTAssertNotEqual(denied.state, restricted.state)
        XCTAssertEqual(manager.requests, 0)
    }

    func testImmediateLocationAuthorizationCannotLoseContinuation() async {
        let manager = LocationManagerStub()
        manager.resultLocation = CLLocation(latitude: 43.318, longitude: 45.698)
        let locator = CityLocator(manager: manager, servicesEnabled: { true })
        let match = await locator.locate()
        XCTAssertNotNil(match)
        XCTAssertEqual(manager.requests, 1)
        XCTAssertEqual(manager.stops, 1)
    }

    func testLocationTimeoutAllowsRetryAndIgnoresLateResults() async {
        let manager = LocationManagerStub()
        manager.authorization = .authorizedAlways
        let locator = CityLocator(manager: manager, servicesEnabled: { true }, requestTimeout: 0.02)
        let timeoutResult = await locator.locate()
        XCTAssertNil(timeoutResult)
        let timedOut = locator.state
        XCTAssertNotEqual(timedOut, .locating)
        locator.locationManager(manager, didUpdateLocations: [CLLocation(latitude: 0, longitude: 0)])
        XCTAssertEqual(locator.state, timedOut)
        manager.resultLocation = CLLocation(latitude: 43.318, longitude: 45.698)
        let retryResult = await locator.locate()
        XCTAssertNotNil(retryResult)
        XCTAssertEqual(manager.requests, 2)
        XCTAssertEqual(manager.stops, 2)
    }

    func testCarbonHotKeyWorksWithoutEventTapAndDoesNotDoubleFire() async throws {
        var presses = 0
        var releases = 0
        let pressed = expectation(description: "press")
        let released = expectation(description: "release")
        let code = UInt32(kVK_F19)
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let controller = HotKeyController(keyCode: code, modifiers: modifiers, id: 0x7ffe,
            onPress: { presses += 1; pressed.fulfill() },
            onRelease: { releases += 1; released.fulfill() })
        defer { controller.stop() }
        XCTAssertNil(controller.register())
        XCTAssertNil(controller.register())
        func send(_ kind: UInt32) throws {
            var event: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind,
                                       0, EventAttributes(kEventAttributeNone), &event), noErr)
            let validEvent = try XCTUnwrap(event)
            var id = EventHotKeyID(signature: 0x415A_4131, id: 0x7ffe)
            XCTAssertEqual(SetEventParameter(validEvent, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id), noErr)
            XCTAssertEqual(SendEventToEventTarget(validEvent, GetApplicationEventTarget()), noErr)
        }
        try send(UInt32(kEventHotKeyPressed))
        XCTAssertTrue(HotKeyController.handleTapKey(keyCode: code,
            carbonModifiers: modifiers, isDown: true))
        try send(UInt32(kEventHotKeyReleased))
        await fulfillment(of: [pressed, released], timeout: 1)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 1)
    }
}

private final class LocationManagerStub: CLLocationManager {
    var authorization: CLAuthorizationStatus = .notDetermined
    var resultLocation: CLLocation?
    var requests = 0
    var stops = 0
    override var authorizationStatus: CLAuthorizationStatus { authorization }
    override func requestWhenInUseAuthorization() {
        authorization = .authorizedAlways
        delegate?.locationManagerDidChangeAuthorization?(self)
    }
    override func requestLocation() {
        requests += 1
        if let location = resultLocation { delegate?.locationManager?(self, didUpdateLocations: [location]) }
    }
    override func stopUpdatingLocation() { stops += 1 }
}

@MainActor
final class NotificationsStub: PrayerNotifications {
    var authorize: () async -> Bool = { false }
    override func requestAuthorization() async -> Bool { await authorize() }
    override func cancelAll(preservingPlayback: Bool = false) {}
}
