import Combine
import Foundation

/// Просмотр примера не означает, что функция включена или ей выдан доступ.
@MainActor
final class OnboardingProgress: ObservableObject {
    enum Step: String, CaseIterable {
        case welcome, dictation, correction, clipboard, phrases, prayer, finish

        static let features: [Step] = [.dictation, .correction, .clipboard, .phrases, .prayer]

        var title: String {
            switch self {
            case .welcome: "Знакомство"
            case .dictation: "Диктовка"
            case .correction: "Автозамена"
            case .clipboard: "Буфер обмена"
            case .phrases: "Фразы"
            case .prayer: "Намаз"
            case .finish: "Завершение"
            }
        }

        var symbol: String {
            switch self {
            case .welcome: "sparkles"
            case .dictation: "mic"
            case .correction: "keyboard"
            case .clipboard: "doc.on.clipboard"
            case .phrases: "text.bubble"
            case .prayer: "moon.stars"
            case .finish: "checkmark.circle"
            }
        }
    }

    static let completedKey = "OnboardingCompleted"
    static let stepKey = "OnboardingStep"
    static let examplesKey = "OnboardingExamples"
    @Published private(set) var step: Step = .welcome
    @Published private(set) var examples: Set<Step> = []
    @Published private(set) var completed = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    /// Первый виток main loop уже видит контейнер настроек macOS.
    func restore() {
        step = Step(rawValue: defaults.string(forKey: Self.stepKey) ?? "") ?? .welcome
        examples = Set((defaults.stringArray(forKey: Self.examplesKey) ?? [])
            .compactMap(Step.init(rawValue:)).filter { Step.features.contains($0) })
        completed = defaults.bool(forKey: Self.completedKey)
    }

    func go(to step: Step) {
        self.step = step
        defaults.set(step.rawValue, forKey: Self.stepKey)
    }

    func move(_ offset: Int) {
        let index = Step.allCases.firstIndex(of: step) ?? 0
        go(to: Step.allCases[min(max(index + offset, 0), Step.allCases.count - 1)])
    }

    func tried(_ step: Step) {
        guard Step.features.contains(step) else { return }
        examples.insert(step)
        defaults.set(examples.map(\.rawValue).sorted(), forKey: Self.examplesKey)
    }

    func complete() {
        completed = true
        defaults.set(true, forKey: Self.completedKey)
    }
}
