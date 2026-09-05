import AppKit

@MainActor
final class IslandPanel: NSPanel {
    // Ключевой панель становится только по требованию (режим буфера
    // с поиском): пассивные режимы не должны отбирать фокус.
    var wantsKey = false
    var isCompact = false
    var onCompactClick: (() -> Void)?
    var onFavoriteShortcut: (() -> Void)?
    private var compactMouseDown = false
    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }
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
