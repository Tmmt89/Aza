import XCTest

@MainActor
final class OnboardingProgressTests: XCTestCase {
    func testResumeSkipAndCompletionRemainSeparateFromExamples() throws {
        let suite = "aza-onboarding-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstRun = OnboardingProgress(defaults: defaults)
        XCTAssertEqual(firstRun.step, .welcome)
        XCTAssertFalse(firstRun.completed)
        firstRun.go(to: .dictation)
        firstRun.tried(.dictation)
        firstRun.move(1) // Закрытие/настройки не завершают знакомство.

        let resumed = OnboardingProgress(defaults: defaults)
        XCTAssertEqual(resumed.step, .correction)
        XCTAssertEqual(resumed.examples, [.dictation])
        XCTAssertFalse(resumed.completed)
        resumed.go(to: .finish) // Можно пропустить остальные функции.
        XCTAssertFalse(resumed.completed)
        resumed.complete()

        let returningUser = OnboardingProgress(defaults: defaults)
        XCTAssertTrue(returningUser.completed)
        returningUser.go(to: .welcome) // Повторный просмотр не включает первый запуск.
        returningUser.move(-1)
        XCTAssertEqual(returningUser.step, .welcome)
        XCTAssertTrue(returningUser.completed)

        defaults.set("unknown-future-step", forKey: OnboardingProgress.stepKey)
        defaults.set(["dictation", "finish", "unknown"], forKey: OnboardingProgress.examplesKey)
        returningUser.restore()
        XCTAssertEqual(returningUser.step, .welcome)
        XCTAssertEqual(returningUser.examples, [.dictation])
        XCTAssertTrue(returningUser.completed) // Совместимость со старым OnboardingCompleted.
    }
}
