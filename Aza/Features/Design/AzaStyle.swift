import SwiftUI

/// Дизайн-система Aza (Design/design-system-state-aza-macos-v1.json):
/// Чёрный остров, графитовые поверхности. Настройки используют единый
/// синий акцент; цвета функций остаются в содержимом острова.
///
/// Раньше эти значения жили приватно внутри IslandView — из-за чего окно
/// настройки выглядело системным, а не частью продукта.
enum AzaStyle {
    // Поверхности
    static let deep = Color.black
    static let stage = Color(red: 14 / 255, green: 14 / 255, blue: 16 / 255)
    static let panel = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let card = Color(red: 22 / 255, green: 22 / 255, blue: 24 / 255)
    static let control = Color(red: 38 / 255, green: 38 / 255, blue: 41 / 255)

    // Текст
    static let ink = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    static let muted = Color(red: 171 / 255, green: 173 / 255, blue: 180 / 255)
    static let faint = Color(red: 142 / 255, green: 145 / 255, blue: 153 / 255)

    // Линии и акценты
    static let line = Color(red: 56 / 255, green: 56 / 255, blue: 58 / 255)
    static let rise = Color(red: 105 / 255, green: 169 / 255, blue: 246 / 255)
    static let violet = Color(red: 184 / 255, green: 158 / 255, blue: 242 / 255)
    static let acid = Color(red: 98 / 255, green: 208 / 255, blue: 154 / 255)
    static let acidSoft = Color(red: 170 / 255, green: 234 / 255, blue: 198 / 255)
    static let acidSurface = acid.opacity(0.12)
    static let danger = Color(red: 1, green: 104 / 255, blue: 96 / 255)
    static let warning = Color(red: 242 / 255, green: 192 / 255, blue: 112 / 255)

    // Стекло: карточка — лёгкий вертикальный градиент поверхности, кромка
    // освещена сверху. Родилось в карточке управления большого острова —
    // равномерная серая рамка выглядела плоской.
    static let glass = LinearGradient(
        colors: [panel, card], startPoint: .top, endPoint: .bottom)
    static let glassEdge = LinearGradient(
        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
        startPoint: .top, endPoint: .bottom)

    static let notchWidth: CGFloat = 160

    // Типографика (стили Aza/* из дизайн-системы)
    static let title = Font.system(size: 20, weight: .semibold)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 12.5, weight: .regular)
    static let label = Font.system(size: 11, weight: .semibold)
    static let caption = Font.system(size: 10.5, weight: .medium)
}

enum AzaMotion {
    static let micro = 0.18
    static let compact = 0.24
    static let expand = 0.32

}

/// Окно настроек с отключённым прижатием к экрану: для анимации ухода
/// кадр честно ставится ВЫШЕ экрана, а стандартный constrain вернул бы
/// титулованное окно в видимую область и сломал бы полёт.
final class AzaSlidingWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

}

/// Появление и уход окон в одном жесте продукта: окно опускается из-за
/// верхней кромки экрана на место, уходит — поднимается обратно за
/// кромку. Без растворения: движение чисто физическое. При включённом
/// «уменьшении движения» окно появляется и прячется мгновенно.
extension NSWindow {
    /// Системный hit-test учитывает модальные окна, их слой и прозрачность.
    func receivesMouse(at point: NSPoint) -> Bool {
        isVisible && NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == windowNumber
    }

    /// Насколько поднять окно, чтобы оно целиком (с тенью) ушло за
    /// верхнюю кромку своего экрана.
    private var offscreenLift: CGFloat {
        let top = (screen ?? NSScreen.main)?.frame.maxY ?? frame.maxY
        return max(0, top - frame.minY) + 60
    }

    func slideIn() {
        let target = frame
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            orderFrontRegardless()
            return
        }
        setFrame(target.offsetBy(dx: 0, dy: offscreenLift), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = AzaMotion.expand
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            animator().setFrame(target, display: true)
        }, completionHandler: {
            azaAssumeMainUnchecked {
                // Прерванная анимация оставляет модельный кадр за кромкой
                // (окно видно, а клики летят «мимо») — финал закрепляется
                // явно. Тот же прямоугольник AppKit ест как no-op, поэтому
                // сдвиг на 1 пт и обратно.
                self.setFrame(target.offsetBy(dx: 0, dy: 1), display: false)
                self.setFrame(target, display: true)
            }
        })
    }

    func slideOut(completion: @escaping @MainActor () -> Void) {
        let target = frame
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AzaMotion.compact
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.4)
            animator().setFrame(target.offsetBy(dx: 0, dy: offscreenLift), display: true)
        } completionHandler: {
            azaAssumeMainUnchecked {
                completion()
                // Спрятанным окно возвращается на место: следующий показ
                // стартует с правильной геометрии.
                self.setFrame(target, display: false)
            }
        }
    }
}

/// Системный переключатель сохраняет клавиатурное управление и семантику VoiceOver.
struct AzaToggleStyle: ToggleStyle {
    var tint: Color = AzaStyle.rise

    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(tint)
    }
}

/// Общая кнопка настроек: спокойная поверхность, компактные скругления.
struct AzaCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = AzaStyle.control
    var foreground: Color = AzaStyle.ink
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AzaStyle.label)
            .foregroundStyle(prominent ? Color.black : foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(prominent ? tint : AzaStyle.control,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(prominent ? .clear : AzaStyle.line.opacity(0.7)))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: AzaMotion.micro), value: configuration.isPressed)
    }
}
