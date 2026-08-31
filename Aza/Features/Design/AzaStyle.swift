import SwiftUI

/// Дизайн-система Aza (Design/design-system-state-aza-macos-v1.json):
/// чистый чёрный «сцены», графитовые поверхности, мягкий изумрудный
/// акцент, спокойная типографика, отступы кратны четырём.
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
    static let muted = Color(red: 161 / 255, green: 161 / 255, blue: 166 / 255)
    static let faint = Color(red: 120 / 255, green: 120 / 255, blue: 126 / 255)

    // Линии и акценты
    static let line = Color(red: 56 / 255, green: 56 / 255, blue: 58 / 255)
    static let rise = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    static let acid = Color(red: 70 / 255, green: 215 / 255, blue: 124 / 255)
    static let acidSoft = Color(red: 114 / 255, green: 232 / 255, blue: 160 / 255)
    static let acidSurface = Color(red: 70 / 255, green: 215 / 255, blue: 124 / 255)
        .opacity(0.12)
    static let danger = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let warning = Color(red: 1, green: 179 / 255, blue: 64 / 255)

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

    /// Приложение никогда не активируется по-настоящему (AppKit роняет
    /// и активирующий клик — память aza-island-clicks), система отклоняет
    /// makeKey, и AppKit рисовал окно «неактивным»: блеклые контролы, ни
    /// рамки фокуса, ни каретки в полях. Принудительный key-статус
    /// возвращает живой вид; события всё равно доставляет CGEventTap.
    override var isKeyWindow: Bool { true }
}

/// Появление и уход окон в одном жесте продукта: окно опускается из-за
/// верхней кромки экрана на место, уходит — поднимается обратно за
/// кромку. Без растворения: движение чисто физическое. При включённом
/// «уменьшении движения» окно появляется и прячется мгновенно.
extension NSWindow {
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
            MainActor.assumeIsolated {
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
            MainActor.assumeIsolated {
                completion()
                // Спрятанным окно возвращается на место: следующий показ
                // стартует с правильной геометрии.
                self.setFrame(target, display: false)
            }
        }
    }
}

/// Переключатель в стиле Aza: капсула с бегунком, изумрудная во
/// включённом состоянии. Системный `.switch` выбивался из тёмной сцены
/// собственным синим и своей геометрией.
struct AzaToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? AzaStyle.acid : AzaStyle.control)
                        .frame(width: 34, height: 20)
                        .overlay(Capsule().stroke(
                            configuration.isOn ? .clear : AzaStyle.line))
                    Circle()
                        .fill(configuration.isOn ? Color.black.opacity(0.85) : AzaStyle.muted)
                        .frame(width: 14, height: 14)
                        .padding(.horizontal, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: AzaMotion.micro), value: configuration.isOn)
    }
}

/// Кнопка-капсула в стиле острова: тёмная подложка, акцент по смыслу.
struct AzaCapsuleButtonStyle: ButtonStyle {
    var tint: Color = AzaStyle.control
    var foreground: Color = AzaStyle.ink
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AzaStyle.label)
            .foregroundStyle(prominent ? Color.black : foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(prominent ? tint : AzaStyle.control, in: Capsule())
            .overlay(Capsule().stroke(prominent ? .clear : AzaStyle.line))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: AzaMotion.micro), value: configuration.isPressed)
    }
}
