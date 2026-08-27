import AppKit
import SwiftUI

private enum AzaStyle {
    // Rise Academy × EL principles, adapted to a native macOS surface.
    static let stage = Color(red: 14 / 255, green: 14 / 255, blue: 16 / 255)
    static let panel = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let deep = Color.black
    static let ink = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    static let muted = Color(red: 161 / 255, green: 161 / 255, blue: 166 / 255)
    static let line = Color(red: 56 / 255, green: 56 / 255, blue: 58 / 255)
    static let rise = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    static let acid = Color(red: 70 / 255, green: 215 / 255, blue: 124 / 255)
    static let acidSoft = Color(red: 114 / 255, green: 232 / 255, blue: 160 / 255)
    static let danger = Color(red: 1, green: 69 / 255, blue: 58 / 255)
    static let notchWidth: CGFloat = 160
}

enum AzaMotion {
    static let micro = 0.18
    static let compact = 0.24
    static let expand = 0.32

    static let reveal = Animation.timingCurve(0.22, 1, 0.36, 1, duration: expand)
}

struct IslandRootView: View {
    @ObservedObject var store: IslandStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            AzaStyle.deep

            Group {
                switch store.mode {
                case .idle:
                    IdleIslandView(store: store)
                case .home:
                    HomeIslandView(store: store)
                case .dictation:
                    DictationIslandView(store: store)
                case .clipboard:
                    ClipboardIslandView(store: store)
                }
            }
            .id(store.mode)
            .padding(.horizontal, store.mode.shoulder)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
            )
        }
        .preferredColorScheme(.dark)
        .clipShape(IslandSilhouette(
            shoulder: store.mode.shoulder,
            bottomRadius: store.mode.bottomRadius
        ))
        .shadow(
            color: .black.opacity(store.mode.shadow.opacity),
            radius: store.mode.shadow.radius,
            y: store.mode.shadow.y
        )
        .animation(
            reduceMotion ? .easeOut(duration: AzaMotion.micro) : AzaMotion.reveal,
            value: store.mode
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aza")
    }
}

struct IslandSilhouette: Shape {
    let shoulder: CGFloat
    let bottomRadius: CGFloat

    init(shoulder: CGFloat, bottomRadius: CGFloat = 34) {
        self.shoulder = shoulder
        self.bottomRadius = bottomRadius
    }

    func path(in rect: CGRect) -> Path {
        guard shoulder > 0 else {
            return RoundedRectangle(cornerRadius: min(23, rect.height / 2), style: .continuous)
                .path(in: rect)
        }

        let s = min(shoulder, rect.width / 4, rect.height / 2)
        let r = min(bottomRadius, (rect.width - s * 2) / 2, rect.height - s)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX - s, y: rect.minY + s),
            control1: CGPoint(x: rect.maxX - s * 0.55, y: rect.minY),
            control2: CGPoint(x: rect.maxX - s, y: rect.minY + s * 0.45)
        )
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r))
        path.addCurve(
            to: CGPoint(x: rect.maxX - s - r, y: rect.maxY),
            control1: CGPoint(x: rect.maxX - s, y: rect.maxY - r * 0.45),
            control2: CGPoint(x: rect.maxX - s - r * 0.45, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + s + r, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX + s, y: rect.maxY - r),
            control1: CGPoint(x: rect.minX + s + r * 0.45, y: rect.maxY),
            control2: CGPoint(x: rect.minX + s, y: rect.maxY - r * 0.45)
        )
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.minY + s))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control1: CGPoint(x: rect.minX + s, y: rect.minY + s * 0.45),
            control2: CGPoint(x: rect.minX + s * 0.55, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct NotchRow<Left: View, Right: View>: View {
    let reservesNotch: Bool
    var height: CGFloat = 38
    var horizontalPadding: CGFloat = 16
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: reservesNotch ? AzaStyle.notchWidth : 0)
            right.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
    }
}

private struct IdleIslandView: View {
    @ObservedObject var store: IslandStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let next = store.prayerCatalog.nextPrayer(cityID: store.selectedPrayerCityID, after: context.date)
            let phase = PrayerCountdownPhase.make(
                secondsRemaining: next?.date.timeIntervalSince(context.date) ?? .infinity
            )
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(next == nil ? AzaStyle.muted : AzaStyle.acid)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phase == .hidden ? "Следующий" : "До намаза")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AzaStyle.muted)
                        Text(next?.kind.title ?? "Нет данных")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(next == nil ? AzaStyle.muted : AzaStyle.ink)
                    }
                }
                .frame(width: 128, alignment: .leading)

                Spacer(minLength: 154)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(countdownText(for: phase, next: next, now: context.date))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(AzaStyle.acid)
                        .contentTransition(.numericText(countsDown: true))
                    Text(next.map { "в \($0.time)" } ?? "расписание")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AzaStyle.muted)
                }
                .frame(width: 92, alignment: .trailing)
            }
            .padding(.horizontal, 28)
            .frame(height: 59)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.mode = .home }
        .accessibilityHint("Открыть Aza")
    }

    private func countdownText(
        for phase: PrayerCountdownPhase,
        next: PrayerOccurrence?,
        now: Date
    ) -> String {
        switch phase {
        case .hidden:
            guard let next else { return "—" }
            let minutes = max(0, Int(next.date.timeIntervalSince(now)) / 60)
            return minutes >= 60 ? "\(minutes / 60)ч \(minutes % 60)м" : "\(minutes)м"
        case .minutes(let value): return "\(value) мин"
        case .seconds(let value): return "\(value) сек"
        }
    }
}

private struct HomeIslandView: View {
    @ObservedObject var store: IslandStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let next = store.prayerCatalog.nextPrayer(cityID: store.selectedPrayerCityID, after: context.date)
            let prayers = store.prayerCatalog.prayers(cityID: store.selectedPrayerCityID, on: context.date)
            VStack(spacing: 0) {
                NotchRow(reservesNotch: store.hasNotch) {
                    Label(next?.kind.title ?? "Нет данных", systemImage: next?.kind.symbol ?? "clock.badge.questionmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(next == nil ? AzaStyle.muted : AzaStyle.acid)
                } right: {
                    Text(next?.countdown(from: context.date) ?? "—")
                        .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(AzaStyle.acid)
                        .contentTransition(.numericText(countsDown: true))
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Следующий намаз")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AzaStyle.muted)
                                .textCase(.uppercase)
                                .tracking(0.8)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(next?.time ?? "—")
                                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(next == nil ? AzaStyle.muted : AzaStyle.acid)
                                    .fontWidth(.condensed)
                                Text(next?.kind.title ?? "Нет данных")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AzaStyle.muted)
                            }
                        }

                        HStack(spacing: 4) {
                            ForEach(prayers, id: \.kind) { prayer in
                                PrayerTimeCell(
                                    prayer: prayer,
                                    isNext: next?.date == prayer.date,
                                    isPast: prayer.date < context.date
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(AzaStyle.deep, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AzaStyle.line))

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Местоположение")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AzaStyle.muted)
                                    .textCase(.uppercase)
                                    .tracking(0.7)
                                Label(store.selectedPrayerCity?.name ?? "Город не выбран", systemImage: "location")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(AzaStyle.ink)
                            }
                            Spacer()
                            Text(store.selectedPrayerCity.map {
                                $0.isComplete ? $0.source.shortName : "\($0.source.shortName) · частично"
                            } ?? "Нет источника")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AzaStyle.acid)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(AzaStyle.deep, in: Capsule())
                                .overlay(Capsule().stroke(AzaStyle.line))
                                .help(store.selectedPrayerCity?.source.name ?? "Нет источника")
                        }
                        Spacer(minLength: 4)
                        Button {
                            if let transcript = store.entries.first(where: { $0.islandKind == .transcript }) {
                                store.reuse(transcript.id)
                            }
                        } label: {
                            Label("Скопировать транскрипт", systemImage: "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AzaStyle.ink)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(AzaStyle.rise, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 4)
                        HStack(spacing: 8) {
                            ActionButton("Диктовка", symbol: "mic", tint: AzaStyle.rise) { store.mode = .dictation }
                            ActionButton("Буфер", symbol: "clipboard", tint: AzaStyle.acid) { store.mode = .clipboard }
                            ActionButton("Настройки", symbol: "gearshape", tint: AzaStyle.muted) {
                                NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                            }
                        }
                    }
                    .frame(width: 238, alignment: .leading)
                    .padding(14)
                    .background(AzaStyle.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AzaStyle.line))
                }
                .frame(height: 166)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
        }
    }
}

private struct PrayerTimeCell: View {
    let prayer: PrayerOccurrence
    let isNext: Bool
    let isPast: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: prayer.kind.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(prayer.kind.title)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text(prayer.time)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(isNext ? Color.black : isPast ? AzaStyle.muted.opacity(0.6) : AzaStyle.ink)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(isNext ? AzaStyle.acid : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if isNext {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AzaStyle.acid)
            }
        }
        .accessibilityLabel("\(prayer.kind.title), \(prayer.time)")
        .accessibilityAddTraits(isNext ? .isSelected : [])
    }
}

private struct DictationIslandView: View {
    @ObservedObject var store: IslandStore

    var body: some View {
        NotchRow(reservesNotch: store.hasNotch, height: 54, horizontalPadding: 28) {
            HStack(spacing: 14) {
                Circle().fill(AzaStyle.acid).frame(width: 12, height: 12)
                WaveformView()
            }
        } right: {
            HStack(spacing: 0) {
                Text(store.dictation.activeLanguage.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AzaStyle.muted)
                    .frame(width: 30, alignment: .trailing)
                Color.clear.frame(width: 4)
                Text(store.dictation.elapsedText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(AzaStyle.ink)
                    .frame(width: 52)
                Color.clear.frame(width: 14)
                Button { store.dictation.stopFromUI() } label: {
                    Image(systemName: "square")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .foregroundStyle(AzaStyle.ink)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 120)
        }
    }
}

private struct WaveformView: View {
    @State private var animates = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let heights: [CGFloat] = [10, 18, 26, 14, 22, 12, 24]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(index.isMultiple(of: 2) ? AzaStyle.acid : AzaStyle.rise)
                    .frame(width: 4, height: heights[index])
                    .scaleEffect(y: reduceMotion || animates ? 1 : 0.45)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.55 + Double(index) * 0.04)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.06),
                        value: animates
                    )
            }
        }
        .frame(width: 58, height: 26)
        .onAppear { animates = !reduceMotion }
        .onChange(of: reduceMotion) { _, value in animates = !value }
    }
}

private struct ClipboardIslandView: View {
    @ObservedObject var store: IslandStore
    @State private var query = ""

    private var visibleEntries: [ClipEntry] {
        store.visibleEntries(matching: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            NotchRow(reservesNotch: store.hasNotch, height: 60, horizontalPadding: 28) {
                HStack(spacing: 6) {
                    SectionButton("История", width: 86, active: !store.showsFavorites) {
                        store.showsFavorites = false
                    }
                    SectionButton("Избранное", width: 98, active: store.showsFavorites) {
                        store.showsFavorites = true
                    }
                }
            } right: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AzaStyle.muted)
                        .frame(width: 18, height: 18)
                    TextField("Поиск…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AzaStyle.ink)
                }
                .padding(.horizontal, 16)
                .frame(width: 250, height: 34)
                .background(AzaStyle.panel, in: Capsule())
                .overlay(Capsule().stroke(AzaStyle.line))
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(visibleEntries) { entry in
                            ClipboardCard(
                                entry: entry,
                                selected: store.selectedID == entry.id,
                                select: { store.selectedID = entry.id },
                                reuse: { store.reuse(entry.id) },
                                favorite: { store.toggleFavorite(entry.id) },
                                delete: { store.delete(entry.id) }
                            )
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 3)
                    .padding(.bottom, 23)
                }
                .scrollIndicators(.hidden)
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .focusable()
        .onKeyPress { press in
            switch press.key {
            case .leftArrow:
                store.moveSelection(by: -1, in: visibleEntries)
                return .handled
            case .rightArrow:
                store.moveSelection(by: 1, in: visibleEntries)
                return .handled
            case .delete:
                if let id = store.selectedID { store.delete(id) }
                return .handled
            case .return:
                if let id = store.selectedID {
                    store.reuse(id)
                }
                return .handled
            case .escape:
                if query.isEmpty { store.mode = .idle } else { query = "" }
                return .handled
            default:
                return .ignored
            }
        }
        .overlay(alignment: .bottom) {
            if !store.commands.pendingUndo.isEmpty {
                Button {
                    store.undoDelete()
                } label: {
                    HStack(spacing: 8) {
                        Text("Удалено")
                        Text("Отменить").foregroundStyle(AzaStyle.acid)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AzaStyle.muted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AzaStyle.panel, in: Capsule())
                    .overlay(Capsule().stroke(AzaStyle.line))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct ClipboardCard: View {
    let entry: ClipEntry
    let selected: Bool
    let select: () -> Void
    let reuse: () -> Void
    let favorite: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    private var accent: Color {
        switch entry.islandKind {
        case .text: AzaStyle.acid
        case .link: AzaStyle.rise
        case .image: AzaStyle.ink
        case .files: AzaStyle.muted
        case .transcript: AzaStyle.acid
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: entry.islandKind.symbol)
                Text(entry.islandKind.title).lineLimit(1)
                Spacer()
                Text(ElapsedTime.short(since: entry.createdAt))
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent)

            if let image = entry.thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if entry.islandKind == .files {
                VStack(spacing: 7) {
                    Image(systemName: "doc.on.doc.fill").font(.system(size: 28))
                    Text(entry.text).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(AzaStyle.ink)
            } else {
                Text(entry.text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AzaStyle.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            HStack(spacing: 6) {
                if let icon = entry.sourceAppIcon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(entry.sourceApp).lineLimit(1)
                Spacer()
                if hovering || entry.favorite {
                    Button(action: favorite) {
                        Image(systemName: entry.favorite ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AzaStyle.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 206, height: 142)
        .background(AzaStyle.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? AzaStyle.acidSoft : AzaStyle.line, lineWidth: selected ? 2 : 1)
        }
        .shadow(color: selected ? AzaStyle.acid.opacity(0.2) : .clear, radius: 18, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(count: 2, perform: reuse)
        .simultaneousGesture(TapGesture().onEnded(select))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(entry.favorite ? "Убрать из избранного" : "В избранное", action: favorite)
            Divider()
            Button("Удалить", role: .destructive, action: delete)
        }
        .accessibilityLabel("\(entry.islandKind.title), \(entry.sourceApp)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    init(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(tint == AzaStyle.acid ? Color.black : AzaStyle.ink)
                    .background(tint, in: Circle())
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(tint == AzaStyle.muted ? AzaStyle.muted : AzaStyle.ink)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct SectionButton: View {
    let title: String
    let width: CGFloat
    let active: Bool
    let action: () -> Void

    init(_ title: String, width: CGFloat, active: Bool, action: @escaping () -> Void) {
        self.title = title
        self.width = width
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? Color.black : AzaStyle.muted)
            .frame(width: width, height: 32)
            .background(active ? AzaStyle.acid : AzaStyle.panel, in: Capsule())
            .overlay(Capsule().stroke(active ? AzaStyle.acid : AzaStyle.line))
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(configuration.isPressed ? AzaStyle.ink : AzaStyle.muted)
            .contentShape(Rectangle())
    }
}
