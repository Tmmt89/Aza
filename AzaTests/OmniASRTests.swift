import XCTest
import Carbon.HIToolbox

@MainActor
final class OmniASRTests: XCTestCase {
    func testChoosingChechenAndPressingDictationDoesNotDownloadOrOpenMicrophone() throws {
        let root = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = DictationController.languageStorageKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set("ce", forKey: key)
        var microphoneChecks = 0
        let dictation = DictationController(clipboardStore: { nil }, omni: OmniASR(root: root),
            microphoneAuthorization: { microphoneChecks += 1; return .notDetermined })
        dictation.languageChanged()
        dictation.startLatchedFromUI()
        UserDefaults.standard.set("ru", forKey: key)
        dictation.shortcutPressed(.omni)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertFalse(dictation.isInstallingOmni)
        XCTAssertFalse(dictation.isLatched)
        XCTAssertEqual(microphoneChecks, 0)
        XCTAssertTrue(dictation.status.contains("Скачать"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertNotEqual(OmniASR.directory, DictationController.modelStorageDirectory)
    }

    func testAlternatingShortcutsOwnTheirRecordingAndDoubleTap() throws {
        let root = try installedRoot()
        let key = DictationController.languageStorageKey
        let previous = UserDefaults.standard.object(forKey: key)
        let previousVariant = UserDefaults.standard.object(forKey: OmniASR.variantStorageKey)
        UserDefaults.standard.set("ctc", forKey: OmniASR.variantStorageKey)
        let dictation = DictationController(clipboardStore: { nil }, omni: OmniASR(root: root),
                                           microphoneAuthorization: { .authorized })
        defer {
            // This synchronous test cancels preparation before audio/model tasks run.
            dictation.stop()
            dictation.unloadModel()
            UserDefaults.standard.set(previous, forKey: key)
            UserDefaults.standard.set(previousVariant, forKey: OmniASR.variantStorageKey)
            try? FileManager.default.removeItem(at: root)
        }
        UserDefaults.standard.set("ce", forKey: key)
        XCTAssertEqual(DictationController.Engine.whisper.language, "auto")
        UserDefaults.standard.set("en", forKey: key)
        dictation.shortcutPressed(.whisper)
        XCTAssertEqual(dictation.state, .preparingRecording)
        XCTAssertEqual(dictation.activeLanguage, "en")
        dictation.shortcutPressed(.omni)
        dictation.shortcutReleased(.omni)
        XCTAssertEqual(dictation.state, .preparingRecording)
        XCTAssertEqual(dictation.activeLanguage, "en")
        XCTAssertFalse(dictation.isLatched)
        dictation.shortcutReleased(.whisper)
        XCTAssertEqual(dictation.state, .idle)

        dictation.shortcutPressed(.omni)
        XCTAssertEqual(dictation.state, .preparingRecording)
        XCTAssertEqual(dictation.activeLanguage, "ce")
        XCTAssertFalse(dictation.isLatched, "Whisper then Omni is not a double tap")
        dictation.shortcutPressed(.whisper)
        dictation.shortcutReleased(.whisper)
        XCTAssertEqual(dictation.state, .preparingRecording)
        dictation.shortcutReleased(.omni)
        XCTAssertEqual(dictation.state, .idle)

        dictation.shortcutPressed(.omni)
        XCTAssertTrue(dictation.isLatched, "Two presses of the same model latch")
        dictation.shortcutReleased(.omni)
        dictation.shortcutPressed(.whisper)
        dictation.shortcutReleased(.whisper)
        XCTAssertEqual(dictation.state, .preparingRecording)
        XCTAssertTrue(dictation.isLatched, "The other model cannot stop latched recording")
        dictation.shortcutPressed(.omni)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertFalse(dictation.isLatched)
        XCTAssertEqual(DictationController.preferredLanguage, "en", "Shortcuts do not change the picker")
        XCTAssertNil(dictation.recordingStartedAt)
    }

    func testBothShortcutsRegisterAndConflictsPreserveBindings() throws {
        let keys = [HotKeyBinding.dictationKey, HotKeyBinding.omniDictationKey, HotKeyBinding.phrasesKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let dictation = DictationController(clipboardStore: { nil }, accessibilityTrusted: { false })
        defer {
            dictation.stop()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
        }
        HotKeyBinding.phrasesDefault.save(HotKeyBinding.phrasesKey)
        let whisper = HotKeyBinding(keyCode: UInt32(kVK_F18), modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey))
        let omni = HotKeyBinding(keyCode: UInt32(kVK_F19), modifiers: whisper.modifiers)
        whisper.save(keys[0])
        omni.save(keys[1])
        XCTAssertNil(dictation.rebindHotKey())
        XCTAssertNil(dictation.rebindHotKey(for: .omni))
        XCTAssertNotNil(whisper.save(keys[1]) { dictation.rebindHotKey(for: .omni) })
        XCTAssertEqual(HotKeyBinding.load(keys[1], fallback: .omniDictationDefault), omni)
        let probe = HotKeyController(keyCode: omni.keyCode, modifiers: omni.modifiers,
                                     id: 0x7ffa, onPress: {})
        defer { probe.stop() }
        XCTAssertEqual(probe.register(), OSStatus(eventHotKeyExistsErr))

        let control = HotKeyBinding(keyCode: UInt32(kVK_RightControl), modifiers: 0)
        XCTAssertNotNil(control.dictationConflict(for: keys[1]), "Bare Control would start before Whisper's combination")
        let fn = HotKeyBinding(keyCode: UInt32(kVK_Function), modifiers: 0)
        XCTAssertNotNil(fn.save(keys[1]) { dictation.rebindHotKey(for: .omni) })
        XCTAssertEqual(HotKeyBinding.load(keys[1], fallback: .omniDictationDefault), omni)
        XCTAssertNil(dictation.omniHotKeyError, "Failed modifier registration restores the working Omni shortcut")
        XCTAssertNil(dictation.hotKeyError)
        let digit = HotKeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey))
        XCTAssertNotNil(digit.phraseSelectionConflict(for: keys[1]))
    }

    func testChoosingLLMDoesNotReuseCTCReadinessOrDownloadAnything() throws {
        let root = try installedRoot()
        let key = OmniASR.variantStorageKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            UserDefaults.standard.set(previous, forKey: key)
            try? FileManager.default.removeItem(at: root)
        }
        UserDefaults.standard.set("llm", forKey: key)
        var microphoneChecks = 0
        let dictation = DictationController(clipboardStore: { nil }, omni: OmniASR(root: root),
            microphoneAuthorization: { microphoneChecks += 1; return .notDetermined })
        dictation.shortcutPressed(.omni)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertEqual(microphoneChecks, 0)
        XCTAssertFalse(dictation.isInstallingOmni)
        XCTAssertTrue(dictation.status.contains(OmniASR.Variant.llm.modelName))
        XCTAssertTrue(OmniASR.isInstalled(.ctc, at: root), "Existing CTC installation remains usable")
        XCTAssertFalse(OmniASR.isInstalled(.llm, at: root))
        UserDefaults.standard.set("unsupported", forKey: key)
        XCTAssertEqual(OmniASR.preferredVariant, .ctc)
    }

    private func installedRoot() throws -> URL {
        let root = try TestFiles.directory()
        let manager = FileManager.default
        let bin = root.appendingPathComponent("python/bin")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: bin.appendingPathComponent("python3"),
                                      withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        // Sparse placeholder: readiness checks its size without allocating 3.9 GB in the test.
        let weights = root.appendingPathComponent("omniASR-CTC-1B-v2.pt")
        manager.createFile(atPath: weights.path, contents: nil)
        let file = try FileHandle(forWritingTo: weights)
        try file.truncate(atOffset: 3_902_956_068)
        try file.close()
        try Data(count: 91_481).write(to: root.appendingPathComponent("omniASR_tokenizer_written_v2.model"))
        XCTAssertFalse(OmniASR.isInstalled(at: root), "Partial installations cannot start inference")
        try OmniASR.installationVersion.write(to: root.appendingPathComponent("ready"),
                                              atomically: true, encoding: .utf8)
        return root
    }

    func testPipeTransportCancellationAndNextWorker() async throws {
        let root = try installedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let bundleRoot = root.appendingPathComponent("Worker.bundle")
        let resources = bundleRoot.appendingPathComponent("Contents/Resources")
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.aza.omni", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleRoot.appendingPathComponent("Contents/Info.plist"))
        let script = """
        import json, pathlib, sys, time
        root = pathlib.Path(sys.argv[2])
        variant = sys.argv[3]
        assert variant in ('ctc', 'llm')
        data = sys.stdin.buffer.read()
        assert len(data) == 16000 * 4 * 3
        print(json.dumps({'status': 'ready'}), flush=True)
        if (root / 'sleep').exists():
            time.sleep(30)
        print(json.dumps({'text': 'Нохчийн мотт' if variant == 'ctc' else 'Нохчийн мотт LLM'}), flush=True)
        """
        try script.write(to: resources.appendingPathComponent("omni-asr.py"), atomically: true, encoding: .utf8)
        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let worker = OmniASR(root: root, resources: bundle)
        let samples = [Float](repeating: 0.1, count: 16000 * 3)
        try Data().write(to: root.appendingPathComponent("sleep"))
        let ready = expectation(description: "worker has consumed pipe input")
        let task = Task { try await worker.transcribe(samples) { status, _ in
            if status == "ready" { ready.fulfill() }
        } }
        await fulfillment(of: [ready], timeout: 10)
        do {
            _ = try await worker.transcribe(samples) { _, _ in }
            XCTFail("Two workers must never run together")
        } catch { XCTAssertTrue(error.localizedDescription.contains("занята")) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must discard the result") }
        catch { XCTAssertTrue(error is CancellationError) }
        try manager.removeItem(at: root.appendingPathComponent("sleep"))
        let text = try await worker.transcribe(samples) { _, _ in }
        XCTAssertEqual(text, "Нохчийн мотт", "A cancelled process cannot poison the next dictation")
        let llm = OmniASR.Variant.llm
        let weights = root.appendingPathComponent(llm.checkpoint)
        manager.createFile(atPath: weights.path, contents: nil)
        let file = try FileHandle(forWritingTo: weights)
        try file.truncate(atOffset: UInt64(llm.size))
        try file.close()
        XCTAssertFalse(worker.isInstalled(.llm))
        try llm.installationVersion.write(to: root.appendingPathComponent(llm.readyFile), atomically: true, encoding: .utf8)
        XCTAssertTrue(worker.isInstalled(.llm))
        let llmText = try await worker.transcribe(samples, variant: .llm) { _, _ in }
        XCTAssertEqual(llmText, "Нохчийн мотт LLM", "The selected variant must reach the Python worker")
        XCTAssertTrue(worker.isInstalled(.ctc))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("audio.wav").path))
        do {
            _ = try await worker.transcribe([.nan]) { _, _ in }
            XCTFail("Invalid audio must not reach the process")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Некорректная")) }
    }
}
