import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit.hidsystem
import XCTest

@MainActor
final class InputSafetyTests: XCTestCase {
    func testNativePasteAcceptsOnlyTheCommandVMenuShortcut() {
        XCTAssertTrue(TextInsertion.isPasteShortcut(character: "V", virtualKey: nil, modifiers: 0))
        XCTAssertTrue(TextInsertion.isPasteShortcut(character: "м", virtualKey: kVK_ANSI_V, modifiers: 0))
        for modifiers in [nil, 1, 2, 4, 8] {
            XCTAssertFalse(TextInsertion.isPasteShortcut(character: "v", virtualKey: kVK_ANSI_V,
                                                        modifiers: modifiers))
        }
        XCTAssertFalse(TextInsertion.isPasteShortcut(character: "c", virtualKey: kVK_ANSI_C, modifiers: 0))
        XCTAssertFalse(TextInsertion.isPasteShortcut(character: nil, virtualKey: nil, modifiers: 0))
    }

    func testWhisperLanguageAndShortcutAfterRemovingChechen() {
        let key = DictationController.languageStorageKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set("ce", forKey: key)
        XCTAssertEqual(DictationController.preferredLanguage, "auto")
        XCTAssertNil(Bundle.main.url(forResource: "omni-asr", withExtension: "py"))
        XCTAssertNil(Bundle.main.url(forResource: "omni-requirements", withExtension: "txt"))
        let dictation = DictationController(clipboardStore: { nil },
                                           microphoneAuthorization: { .authorized })
        defer {
            // Cancel preparation before queued audio/model tasks can run.
            dictation.stop()
            dictation.unloadModel()
            UserDefaults.standard.set(previous, forKey: key)
        }
        UserDefaults.standard.set("en", forKey: key)
        dictation.shortcutPressed()
        XCTAssertEqual(dictation.state, .preparingRecording)
        XCTAssertEqual(dictation.activeLanguage, "en")
        UserDefaults.standard.set("ru", forKey: key)
        XCTAssertEqual(dictation.activeLanguage, "en", "Language belongs to the current recording")
        dictation.shortcutReleased()
        XCTAssertEqual(dictation.state, .idle)
        dictation.shortcutPressed()
        XCTAssertTrue(dictation.isLatched, "A quick second press still latches Whisper")
        XCTAssertEqual(dictation.activeLanguage, "ru")
        dictation.shortcutReleased()
        XCTAssertEqual(dictation.state, .preparingRecording)
        dictation.shortcutPressed()
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertFalse(dictation.isLatched)
    }

    func testDictationShortcutRestoresWorkingBindingAfterRegistrationFailure() {
        let key = HotKeyBinding.dictationKey
        let previous = UserDefaults.standard.object(forKey: key)
        let dictation = DictationController(clipboardStore: { nil }, accessibilityTrusted: { false })
        defer {
            dictation.stop()
            UserDefaults.standard.set(previous, forKey: key)
        }
        let binding = HotKeyBinding(keyCode: UInt32(kVK_F18),
                                    modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey))
        binding.save(key)
        XCTAssertNil(dictation.rebindHotKey())
        let fn = HotKeyBinding(keyCode: UInt32(kVK_Function), modifiers: 0)
        XCTAssertNotNil(fn.save(key, registering: dictation.rebindHotKey))
        XCTAssertEqual(HotKeyBinding.load(key, fallback: .dictationDefault), binding)
        XCTAssertNil(dictation.hotKeyError)
        let probe = HotKeyController(keyCode: binding.keyCode, modifiers: binding.modifiers,
                                     id: 0x7ffa, onPress: {})
        defer { probe.stop() }
        XCTAssertEqual(probe.register(), OSStatus(eventHotKeyExistsErr))
    }

    func testStoppedHotKeyDropsQueuedCallbacksEvenAfterReregistering() {
        let code = UInt32(kVK_F17)
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        var calls: [String] = []
        let controller = HotKeyController(keyCode: code, modifiers: modifiers, id: 0x7ff9,
            onPress: { calls.append("down") }, onRelease: { calls.append("up") })
        defer { controller.stop() }
        func send(_ down: Bool, marker: Int64 = 0) -> Bool {
            HotKeyController.handleTapKey(keyCode: code, carbonModifiers: down ? modifiers : 0,
                                         isDown: down, sourceUserData: marker)
        }
        XCTAssertNil(controller.register())
        XCTAssertFalse(send(true, marker: TextInsertion.syntheticEventMarker))
        XCTAssertTrue(send(true))
        XCTAssertFalse(send(false, marker: TextInsertion.syntheticEventMarker),
                       "служебное отпускание не сбрасывает физическое удержание")
        XCTAssertTrue(send(false))
        controller.stop()
        XCTAssertNil(controller.register())
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertTrue(calls.isEmpty, "stop отменяет press и release прежней регистрации")
        XCTAssertTrue(send(true))
        XCTAssertTrue(send(false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(calls, ["down", "up"], "быстрое нажатие не теряет ни одну границу")
    }

    func testPhraseShiftVariantsAndConflictsAreCheckedBeforeSaving() {
        let keys = [HotKeyBinding.phrasesKey, HotKeyBinding.clipboardKey, HotKeyBinding.dictationKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) } }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        let shifted = UInt32(controlKey | shiftKey)
        XCTAssertEqual(HotKeyBinding.phrasesDefault.phraseDigitModifiers,
                       [UInt32(optionKey), UInt32(optionKey | shiftKey), UInt32(controlKey), shifted])
        let option = HotKeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | shiftKey))
        XCTAssertEqual(option.phraseDigitModifiers, [UInt32(optionKey), UInt32(optionKey | shiftKey)],
                       "одинаковые варианты не регистрируются дважды")
        var registrations = 0
        func register() -> OSStatus? { registrations += 1; return nil }
        for key in keys {
            for mods in [UInt32(optionKey), UInt32(optionKey | shiftKey), UInt32(controlKey), shifted] {
                let digit = HotKeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: mods)
                XCTAssertNotNil(digit.save(key, registering: register))
                XCTAssertNil(UserDefaults.standard.object(forKey: key))
            }
        }
        XCTAssertEqual(registrations, 0, "конфликт проверяется до сохранения и снятия старого хоткея")
        let clipboard = HotKeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey))
        XCTAssertNil(clipboard.save(HotKeyBinding.clipboardKey, registering: register))
        let phrases = HotKeyBinding(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | shiftKey))
        XCTAssertNotNil(phrases.save(HotKeyBinding.phrasesKey, registering: register),
                        "обратный порядок: новое сочетание фраз конфликтует с уже назначенным буфером")
        XCTAssertNil(UserDefaults.standard.object(forKey: HotKeyBinding.phrasesKey))
    }

    func testClipboardAndPhrasesCannotHideDictation() async {
        let prayer = PrayerStore(notifications: NotificationsStub())
        let dictation = DictationController(clipboardStore: { nil }, microphoneAuthorization: { .denied })
        let island = IslandStore(startup: ClipboardStartup(), dictation: dictation,
                                 prayer: prayer, registerShortcuts: false)
        island.show(.home)
        XCTAssertEqual(island.mode, .home)
        island.show(.dictation)
        for mode in [IslandMode.clipboard, .phrases, .home, .idle] {
            island.show(mode)
            XCTAssertEqual(island.mode, .dictation)
            XCTAssertTrue(island.isIslandVisible)
        }
        island.dismissIsland()
        XCTAssertEqual(island.mode, .dictation)
        dictation.stop()
        await prayer.shutdownForCleanup()
    }

    func testRecorderReceivesCommandKeysAndCancelsOnFocusLoss() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = KeyCatcher.CatcherView()
        var received: [UInt16] = []
        recorder.onKey = { received.append($0.keyCode) }
        window.contentView = recorder
        window.orderFrontRegardless()
        defer {
            recorder.endRecording()
            recorder.stopObserving()
            window.close()
        }
        for code in [kVK_ANSI_B, kVK_ANSI_W, kVK_ANSI_Q, kVK_ANSI_Comma] {
            _ = window.makeFirstResponder(nil)
            XCTAssertTrue(window.makeFirstResponder(recorder))
            XCTAssertTrue(HotKeyController.isRecordingShortcut)
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil,
                virtualKey: CGKeyCode(code), keyDown: true))
            event.flags = [.maskCommand, .maskShift]
            XCTAssertTrue(KeyCatcher.forward(event, to: window))
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            XCTAssertEqual(received.last, UInt16(code))
            XCTAssertFalse(HotKeyController.isRecordingShortcut)
            _ = window.makeFirstResponder(nil)
            XCTAssertTrue(window.makeFirstResponder(recorder))
            XCTAssertTrue(recorder.performKeyEquivalent(with: try XCTUnwrap(NSEvent(cgEvent: event))))
            XCTAssertEqual(received.last, UInt16(code), "нативный путь AppKit тоже получает команду")
            XCTAssertFalse(HotKeyController.isRecordingShortcut)
        }
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.makeFirstResponder(recorder))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(HotKeyController.isRecordingShortcut, "потеря первого респондера отменяет запись")

        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didResignActiveNotification] {
            _ = window.makeFirstResponder(nil)
            XCTAssertTrue(window.makeFirstResponder(recorder))
            NotificationCenter.default.post(name: name, object: window)
            XCTAssertFalse(HotKeyController.isRecordingShortcut, name.rawValue)
        }
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.makeFirstResponder(recorder))
        let tab = try XCTUnwrap(CGEvent(keyboardEventSource: nil,
                                       virtualKey: CGKeyCode(kVK_Tab), keyDown: true))
        tab.flags = .maskCommand
        XCTAssertFalse(KeyCatcher.forward(tab, to: window), "⌘Tab уходит системе")
        XCTAssertFalse(HotKeyController.isRecordingShortcut)
        _ = window.makeFirstResponder(nil)
        XCTAssertTrue(window.makeFirstResponder(recorder))
        let delayed = try XCTUnwrap(CGEvent(keyboardEventSource: nil,
                                           virtualKey: CGKeyCode(kVK_ANSI_B), keyDown: true))
        XCTAssertTrue(KeyCatcher.forward(delayed, to: window))
        _ = window.makeFirstResponder(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(received.count, 8, "отмена отбрасывает и уже отложенное нажатие")
    }

    func testModifierReleaseTracksPhysicalSideWithBothKeysHeld() throws {
        let pairs: [(Int, Int, Int32, Int32, CGEventFlags)] = [
            (kVK_Control, kVK_RightControl, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK, .maskControl),
            (kVK_Shift, kVK_RightShift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK, .maskShift),
            (kVK_Option, kVK_RightOption, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK, .maskAlternate),
            (kVK_Command, kVK_RightCommand, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK, .maskCommand),
        ]
        for (left, right, leftMask, rightMask, combined) in pairs {
            for (own, other, ownMask, otherMask) in [(left, right, leftMask, rightMask),
                                                    (right, left, rightMask, leftMask)] {
                var presses = 0
                var releases = 0
                let monitor = try XCTUnwrap(ModifierKeyMonitor(keyCode: UInt16(own),
                    onPress: { presses += 1 }, onRelease: { releases += 1 }))
                func send(_ key: Int, _ masks: Int32) throws {
                    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil,
                        virtualKey: CGKeyCode(key), keyDown: true))
                    event.type = .flagsChanged
                    event.flags = masks == 0 ? []
                        : CGEventFlags(rawValue: combined.rawValue | UInt64(masks))
                    monitor.handle(try XCTUnwrap(NSEvent(cgEvent: event)))
                }
                try send(own, ownMask)
                try send(other, ownMask | otherMask)
                try send(own, otherMask)
                XCTAssertEqual(releases, 1, "своя клавиша отпущена, другая ещё зажата")
                XCTAssertEqual(presses, 1, "отпускание правого Shift при зажатом левом не является вторым тапом")
                try send(other, 0)
                try send(own, ownMask)
                try send(other, ownMask | otherMask)
                try send(other, ownMask)
                XCTAssertEqual(releases, 1, "отпускание другой стороны не завершает удержание")
                try send(own, 0)
                XCTAssertEqual(presses, 2)
                XCTAssertEqual(releases, 2)
                monitor.stop()
            }
        }
    }

    func testDeniedModifierShortcutRestoresWorkingDictationShortcut() throws {
        let key = HotKeyBinding.dictationKey
        let previous = UserDefaults.standard.object(forKey: key)
        let original = HotKeyBinding(keyCode: UInt32(kVK_F17),
                                    modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey))
        let dictation = DictationController(clipboardStore: { nil },
            microphoneAuthorization: { .denied }, accessibilityTrusted: { false })
        defer {
            dictation.stop()
            UserDefaults.standard.set(previous, forKey: key)
        }
        original.save(key)
        XCTAssertNil(dictation.rebindHotKey())
        let fn = HotKeyBinding(keyCode: UInt32(kVK_Function), modifiers: 0)
        let error = fn.save(key, registering: dictation.rebindHotKey)
        XCTAssertTrue(try XCTUnwrap(error).contains("Универсальный доступ"))
        XCTAssertEqual(HotKeyBinding.load(key, fallback: .dictationDefault), original)
        XCTAssertNil(dictation.hotKeyError, "успешный откат очищает текущую ошибку")
        let probe = HotKeyController(keyCode: original.keyCode, modifiers: original.modifiers,
                                     id: 0x7ffb, onPress: {})
        defer { probe.stop() }
        XCTAssertEqual(probe.register(), OSStatus(eventHotKeyExistsErr),
                       "прежняя клавиша действительно снова зарегистрирована")
        // При старте с сохранённым Fn ошибка остаётся видимой и без открытого рекордера.
        fn.save(key)
        XCTAssertEqual(dictation.rebindHotKey(), OSStatus(permErr))
        XCTAssertTrue(try XCTUnwrap(dictation.hotKeyError).contains("Универсальный доступ"))
    }

    func testScreenCaptureSelectionYieldsInputButThumbnailDoesNot() {
        let screen = CGSize(width: 1728, height: 1078)
        func window(_ owner: String, _ width: CGFloat, _ height: CGFloat,
                    layer: Int = 1000, alpha: Double = 1) -> [String: Any] {
            [kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: ["Width": width, "Height": height]]
        }
        func selecting(_ windows: [[String: Any]], screens: [CGSize] = [CGSize(width: 1728, height: 1078)]) -> Bool {
            SystemScreenCapture.hasSelectionOverlay(
                in: windows, screenSizes: screens)
        }
        let overlay = window("screencaptureui", screen.width, 1117)
        XCTAssertTrue(selecting([window("Aza", 820, 680, layer: 0), overlay]),
                      "системный слой важнее настроек, открытого меню и острова")
        XCTAssertFalse(selecting([window("screencaptureui", 320, 180)]),
                       "миниатюра готового снимка не блокирует ввод Aza")
        XCTAssertFalse(selecting([window("screencaptureui", 1728, 1117, alpha: 0)]),
                       "неактивный невидимый слой не блокирует ввод Aza")
        XCTAssertFalse(selecting([window("Other app", 1728, 1117)]),
                       "обычное полноэкранное приложение не является выделением области")
        XCTAssertFalse(selecting([]), "после отмены выделения ввод возвращается")
        XCTAssertFalse(selecting([[kCGWindowOwnerName as String: "screencaptureui"]]))
        XCTAssertTrue(selecting([window("screencapture", 1280, 800)],
                                 screens: [screen, CGSize(width: 1280, height: 760)]),
                      "выделение на втором дисплее тоже получает весь жест")
    }

    func testHiddenSettingsWindowNeverClaimsKeyboardFocus() {
        _ = NSApplication.shared
        let window = AzaSlidingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        XCTAssertFalse(window.isKeyWindow, "ещё не показанные настройки не принимают клавиши")
        window.becomeKey()
        window.resignKey()
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow, "закрытое окно не должно удерживать ввод")
    }

    func testCompactPanelOpensOnNativeClickWithoutAnEventTap() async throws {
        _ = NSApplication.shared
        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isCompact = true
        var opened = 0
        let click = expectation(description: "native compact click")
        panel.onCompactClick = { opened += 1; click.fulfill() }
        defer { panel.close() }
        func send(_ type: NSEvent.EventType, at point: NSPoint = NSPoint(x: 100, y: 16)) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 0))
            panel.sendEvent(event)
        }
        try send(.leftMouseDown)
        XCTAssertEqual(opened, 0)
        try send(.leftMouseUp)
        await fulfillment(of: [click], timeout: 2)
        XCTAssertEqual(opened, 1)
        try send(.leftMouseDown)
        try send(.leftMouseUp, at: NSPoint(x: 300, y: 16))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(opened, 1, "отпускание снаружи отменяет клик")
        XCTAssertFalse(panel.isKeyWindow, "компактный клик не забирает клавиатуру")
    }

    func testTechnicalTokensNeverProduceCorrectionCandidates() {
        let monitor = WordMonitor { _, _ in }
        let punctuation: Set<Character> = ["1", "[", "]", ";", "'", ",", "."]
        let emailTokens = "%&*^|~{}!?".map { "ghbdtn\($0)tag@example.com " }
        for token in ["ghbdtn@example.com ", "https://site.test/ghbdtn ",
                      "ghbdtn_name ", "ghbdtn2 ", "user@ghbdtn.test ",
                      "ghbdtn+tag@example.com ", "ghbdtn-name@example.com "] + emailTokens {
            // Настоящий монитор получает последовательность отдельных клавиш.
            let words = token.flatMap {
                monitor.accumulateCharacters(String($0), wordPunctuation: punctuation)
            }
            XCTAssertTrue(words.isEmpty, token)
        }
        let ordinary = monitor.accumulateCharacters("ghbdtn 1алам ghbdtn!? ", wordPunctuation: punctuation)
        XCTAssertEqual(ordinary.map(\.word), ["ghbdtn", "1алам", "ghbdtn!?"])
        XCTAssertEqual(ordinary.map(\.delimiter), [" ", " ", " "])
        // Русские прописные на { / } / ~ не должны стать исключениями.
        let shifted = punctuation.union(["{", "}", "~"])
        XCTAssertEqual(monitor.accumulateCharacters("{mj ", wordPunctuation: shifted).map(\.word), ["{mj"])
        for token in emailTokens {
            XCTAssertTrue(monitor.accumulateCharacters(token, wordPunctuation: shifted).isEmpty)
        }
    }

    func testUserWordCanonicalizationAndUnreadableFileProtection() throws {
        XCTAssertEqual(UserWordLists.storageForm("гIала"), UserWordLists.storageForm("г1ала"))
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("user-words.json")
        let original = Data("invalid JSON".utf8)
        try original.write(to: file)
        let lists = UserWordLists(fileURL: file)
        lists.addNeverCorrect("гIала")
        XCTAssertTrue(lists.isNeverCorrect("г1ала"))
        XCTAssertTrue(lists.isUnreadable)
        XCTAssertTrue(lists.lastSaveFailed)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAXReplacementUsesUTF16Offsets() {
        let expected = "и\u{0306}😀 "
        let range = TextInsertion.replacementRange(before: 9, expecting: expected)
        XCTAssertEqual(expected.count, 3)
        XCTAssertEqual(range?.location, 4)
        XCTAssertEqual(range?.length, 5)
        XCTAssertNil(TextInsertion.replacementRange(before: 4, expecting: expected))
        XCTAssertNil(TextInsertion.replacementRange(before: 4, expecting: ""))
    }

    func testPasteRejectsAnUnavailableOriginalField() {
        XCTAssertFalse(TextInsertion.focusSafeForPaste(
            targetPid: nil, verifying: AXUIElementCreateApplication(-1)))
        XCTAssertFalse(TextInsertion.postPasteCommand(
            targetPid: -1, verifying: AXUIElementCreateApplication(-1)))
    }

    func testDirectDictationRequiresAKnownOriginalTarget() {
        let unavailable = AXUIElementCreateApplication(-1)
        for pid: pid_t? in [nil, 0, -1] {
            XCTAssertFalse(TextInsertion.insertIntoFocusedField(
                "Не вставлять", targetPid: pid, verifying: unavailable))
        }
        XCTAssertFalse(TextInsertion.insertIntoFocusedField(
            "Не вставлять", targetPid: ProcessInfo.processInfo.processIdentifier, verifying: nil),
            "Без исходного поля адресная вставка невозможна")
        XCTAssertFalse(TextInsertion.insertIntoFocusedField(
            "Не вставлять", targetPid: ProcessInfo.processInfo.processIdentifier,
            verifying: unavailable), "Исчезнувшее поле не разрешает вставку в новое")
    }

    func testOutOfRangeStoredKeyCodeDoesNotTrap() throws {
        let data = Data(#"{"keyCode":65536,"modifiers":0}"#.utf8)
        let binding = try JSONDecoder().decode(HotKeyBinding.self, from: data)
        XCTAssertFalse(binding.isModifierOnly)
    }

    func testShortcutReassignmentRestoresWorkingBindingOnConflict() {
        let key = "AzaTests.HotKey.\(UUID().uuidString)"
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let original = HotKeyBinding(keyCode: UInt32(kVK_F18), modifiers: modifiers)
        let occupied = HotKeyBinding(keyCode: UInt32(kVK_F19), modifiers: modifiers)
        let available = HotKeyBinding(keyCode: UInt32(kVK_F20), modifiers: modifiers)
        let other = HotKeyController(keyCode: occupied.keyCode, modifiers: modifiers,
                                     id: 0x7ffd, onPress: {})
        var current: HotKeyController?
        defer {
            current?.stop()
            other.stop()
            UserDefaults.standard.removeObject(forKey: key)
        }
        func register() -> OSStatus? {
            current?.stop()
            let binding = HotKeyBinding.load(key, fallback: original)
            let controller = HotKeyController(keyCode: binding.keyCode, modifiers: binding.modifiers,
                                              id: 0x7ffe, onPress: {})
            current = controller
            return controller.register()
        }
        func responds(to binding: HotKeyBinding) -> Bool {
            let handled = HotKeyController.handleTapKey(
                keyCode: binding.keyCode, carbonModifiers: binding.modifiers, isDown: true)
            _ = HotKeyController.handleTapKey(
                keyCode: binding.keyCode, carbonModifiers: 0, isDown: false)
            return handled
        }
        XCTAssertNil(other.register())
        XCTAssertNil(register())
        // Конфликт не меняет ни неявное значение по умолчанию, ни сохранённое.
        XCTAssertNotNil(occupied.save(key, registering: register))
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertTrue(responds(to: original))
        original.save(key)
        let saved = UserDefaults.standard.data(forKey: key)
        XCTAssertNotNil(occupied.save(key, registering: register))
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), saved)
        XCTAssertTrue(responds(to: original))
        // Успешное назначение и повторный выбор той же клавиши работают сразу.
        XCTAssertNil(available.save(key, registering: register))
        XCTAssertEqual(HotKeyBinding.load(key, fallback: original), available)
        XCTAssertFalse(responds(to: original))
        XCTAssertTrue(responds(to: available))
        XCTAssertNil(available.save(key, registering: register))
        XCTAssertTrue(responds(to: available))
        XCTAssertTrue(occupied.save(key, registering: { OSStatus(paramErr) })?
            .contains("Прежнее сочетание тоже недоступно") == true)
        XCTAssertEqual(HotKeyBinding.load(key, fallback: original), available)
    }

    func testModifierShortcutDoesNotStartWhileRecordingABinding() throws {
        var presses = 0
        var releases = 0
        let monitor = try XCTUnwrap(ModifierKeyMonitor(
            keyCode: UInt16(kVK_Function), onPress: { presses += 1 },
            onRelease: { releases += 1 }))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil,
                                          virtualKey: CGKeyCode(kVK_Function), keyDown: true))
        event.type = .flagsChanged
        event.flags = .maskSecondaryFn
        let down = try XCTUnwrap(NSEvent(cgEvent: event))
        defer { HotKeyController.isRecordingShortcut = false }
        HotKeyController.isRecordingShortcut = true
        monitor.handle(down)
        XCTAssertEqual(presses, 0)
        HotKeyController.isRecordingShortcut = false
        monitor.handle(down)
        XCTAssertEqual(presses, 1)
        HotKeyController.isRecordingShortcut = true
        event.flags = []
        monitor.handle(try XCTUnwrap(NSEvent(cgEvent: event)))
        XCTAssertEqual(releases, 1)
    }

    func testShortcutRecordingLetsAnAlreadyRegisteredKeyReachTheRecorder() {
        let code = UInt32(kVK_F20)
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let controller = HotKeyController(keyCode: code, modifiers: modifiers,
                                          id: 0x7fff, onPress: {})
        defer {
            HotKeyController.isRecordingShortcut = false
            controller.stop()
        }
        XCTAssertNil(controller.register())
        HotKeyController.isRecordingShortcut = true
        XCTAssertFalse(HotKeyController.handleTapKey(
            keyCode: code, carbonModifiers: modifiers, isDown: true))
        HotKeyController.isRecordingShortcut = false
        XCTAssertTrue(HotKeyController.handleTapKey(
            keyCode: code, carbonModifiers: modifiers, isDown: true))
        XCTAssertTrue(HotKeyController.handleTapKey(
            keyCode: code, carbonModifiers: 0, isDown: false))
    }
}
