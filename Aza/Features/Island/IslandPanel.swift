import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandReveal: ObservableObject {
    @Published var isRevealed = false
}

@MainActor
final class IslandPanel: NSPanel {
    // Ключевой панель становится только по требованию (режим буфера
    // с поиском): пассивные режимы не должны отбирать фокус.
    var wantsKey = false
    var isCompact = false
    var isBottomClipboard = false
    var usesNotchReveal = false
    let reveal = IslandReveal()
    private var revealGeneration = 0
    var onCompactClick: (() -> Void)?
    var onFavoriteShortcut: (() -> Void)?
    private var compactMouseDown = false
    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }

    /// Раскрываем маску SwiftUI в неизменном кадре окна. Следующий виток
    /// даёт hosting-вью отрисовать закрытую маску перед первым раскрытием.
    func revealAtNotch(animated: Bool = true) {
        revealGeneration += 1
        let generation = revealGeneration
        ignoresMouseEvents = false
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            withAnimation(nil) { reveal.isRevealed = true }
            orderFrontRegardless()
            return
        }
        orderFrontRegardless()
        contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revealGeneration == generation, self.isVisible else { return }
            withAnimation(.smooth(duration: 0.42)) { self.reveal.isRevealed = true }
        }
    }

    func dismissAtNotch(animated: Bool = true, completion: @escaping () -> Void = {}) {
        revealGeneration += 1
        let generation = revealGeneration
        ignoresMouseEvents = true
        if isKeyWindow { resignKey() }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            withAnimation(nil) { reveal.isRevealed = false }
            orderOut(nil)
            completion()
            return
        }
        // Удаляем именно уходящее окно и только после сжатия маски.
        // Повторный показ отменяет старое завершение, включая show-hide-show.
        withAnimation(.smooth(duration: 0.28), completionCriteria: .removed) {
            reveal.isRevealed = false
        } completion: {
            // Completion SwiftUI может прийти во время commit Core Animation.
            // Порядок окон меняем на следующем витке AppKit.
            DispatchQueue.main.async {
                guard self.revealGeneration == generation else { return }
                self.orderOut(nil)
                completion()
            }
        }
    }

    static func isClipboardPreviewCloseKey(_ event: NSEvent) -> Bool {
        (event.type == .keyDown || event.type == .keyUp)
            && (event.keyCode == 49 || event.keyCode == 53) // Space / Escape
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    /// Двигается содержимое, а кадр окна остаётся финальным: иначе
    /// WindowServer запоминает неверную область кликов при первом показе.
    func revealFromBottom(animated: Bool = true) {
        ignoresMouseEvents = false
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.setFrameOrigin(.zero)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            orderFrontRegardless()
            return
        }
        contentView.setFrameOrigin(NSPoint(x: 0, y: -frame.height - 8))
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.36
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            contentView.animator().setFrameOrigin(.zero)
        }
    }

    func dismissToBottom(animated: Bool = true) {
        ignoresMouseEvents = true
        if isKeyWindow { resignKey() }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let contentView else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            contentView.animator().setFrameOrigin(NSPoint(x: 0, y: -frame.height - 8))
        } completionHandler: {
            azaAssumeMainUnchecked { self.orderOut(nil) }
        }
    }
    /// Контекстное меню карточек (.contextMenu): hosting-вью отдаёт NSMenu
    /// через menu(for:), но по цепочке ответчиков от вложенного
    /// HostingScrollView правый клик до показа меню не доходит (проверено
    /// 04.09: menu(for:) у hit-вью nil, tracking NSMenu не начинается).
    /// Показываем сами штатным popUpContextMenu.
    override func sendEvent(_ event: NSEvent) {
        if wantsKey, event.type == .keyDown || event.type == .keyUp,
           event.keyCode == 2, event.modifierFlags.contains(.command),
           let onFavoriteShortcut {
            if event.type == .keyDown, !event.isARepeat { onFavoriteShortcut() }
            return
        }
        // Нативный путь нужен и без Accessibility. CGEventTap, если он
        // работает, поглощает компактный клик до доставки в NSPanel.
        let isCompactMouseEvent = event.type == .leftMouseDown || event.type == .leftMouseUp
        let inside = isCompactMouseEvent
            && NSRect(origin: .zero, size: frame.size).contains(event.locationInWindow)
        if isCompact, event.type == .leftMouseDown, inside {
            compactMouseDown = true
            return
        }
        if compactMouseDown, event.type == .leftMouseDragged { return }
        if compactMouseDown, event.type == .leftMouseUp {
            compactMouseDown = false
            if isCompact, inside {
                // Смена SwiftUI-режима — после завершения доставки up.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCompact else { return }
                    self.onCompactClick?()
                }
            }
            return
        }
        if event.type == .rightMouseDown, let host = contentView,
           let menu = host.menu(for: event) {
            azaDebugLog("Aza: panel context menu \(menu.items.map(\.title))")
            NSMenu.popUpContextMenu(menu, with: event, for: host)
            return
        }
        super.sendEvent(event)
    }
}
