import AppKit
import Carbon.HIToolbox
import SwiftUI

struct IslandRootView: View {
    @ObservedObject var store: IslandStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// «Выезд» при смене режима: окно анимировать нельзя (ломает доставку
    /// кликов — см. IslandPanelController.transition), поэтому из-за
    /// кромки опускается сам контент внутри уже финального кадра.
    @State private var slideOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            AzaStyle.deep
            // Едва заметный свет сверху: плоский чёрный превращается в
            // сцену с глубиной, как у настоящего Dynamic Island.
            LinearGradient(
                colors: [Color.white.opacity(0.055), .clear],
                startPoint: .top, endPoint: .bottom
            )

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
                case .phrases:
                    PhrasesIslandView(store: store)
                }
            }
            .id(store.mode)
            .padding(.horizontal, store.mode.shoulder)
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
        // Смену режима контент НЕ анимирует: панель целиком опускается
        // из выреза уже в новом облике (IslandPanelController), и морф
        // содержимого внутри летящего окна давал бы кашу из двух анимаций.
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
    var notchWidth: CGFloat = AzaStyle.notchWidth
    var height: CGFloat = 38
    var horizontalPadding: CGFloat = 16
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    /// Воздух между текстом и кромкой выреза с каждой стороны.
    private let notchGutter: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: reservesNotch ? notchWidth + notchGutter * 2 : 0)
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
            let next = store.nextPrayerOccurrence(after: context.date)
            let phase = PrayerCountdownPhase.make(
                secondsRemaining: next?.date.timeIntervalSince(context.date) ?? .infinity
            )
            let soon = phase != .hidden
            let today = store.todayPrayers()
            // Намаз, наступивший в последние две минуты: «Сейчас Фаджр»
            // вместо обратного отсчёта до следующего.
            let current = today.last {
                $0.date <= context.date && context.date.timeIntervalSince($0.date) < 120
            }
            NotchRow(reservesNotch: store.hasNotch, notchWidth: store.notchWidth,
                     height: store.hasNotch ? store.notchHeight : 40,
                     horizontalPadding: 16) {
                HStack(spacing: 8) {
                    if let copy = store.recentCopy {
                        badge {
                            if let icon = copy.sourceAppIcon {
                                Image(nsImage: icon).resizable().scaledToFit()
                                    .frame(width: 15, height: 15)
                            } else {
                                Image(systemName: copy.islandKind.symbol)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AzaStyle.acid)
                            }
                        }
                        titles(caption: "Скопировано",
                               title: copy.islandKind.title, active: true)
                    } else {
                        badge {
                            Image(systemName: (current ?? next)?.kind.symbol
                                              ?? "clock.badge.questionmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(next == nil && current == nil
                                                 ? AzaStyle.muted : AzaStyle.acid)
                        }
                        titles(caption: current != nil ? "Сейчас" : soon ? "Скоро" : "Следующий",
                               title: (current ?? next)?.kind.title ?? "Нет данных",
                               active: next != nil || current != nil)
                    }
                }
            } right: {
                // Во время вспышки «Скопировано» правая сторона пустует:
                // намаз и копирование — разные события, вместе они шумят.
                if store.recentCopy == nil, next != nil {
                    // Последние минуты: счётчик теплеет и мягко пульсирует в
                    // такт секундам таймлайна.
                    let pulseDim = soon && Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0
                    // Счётчик — акцентом, абсолютное время — мелким
                    // приглушённым: разная роль читается разным весом.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Пока слева «Сейчас Фаджр», счётчик уже считает до
                        // СЛЕДУЮЩЕГО события — без имени он читается как
                        // время до текущего намаза.
                        if current != nil, let next {
                            Text(next.kind.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AzaStyle.muted)
                        }
                        Text("через " + countdownText(for: phase, next: next, now: context.date))
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(soon ? AzaStyle.warning : AzaStyle.acid)
                            .opacity(pulseDim ? 0.55 : 1)
                            .animation(.easeInOut(duration: 1), value: pulseDim)
                            .contentTransition(.numericText(countsDown: true))
                        Text(next.map { "в \($0.time)" } ?? "")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AzaStyle.faint)
                    }
                    .lineLimit(1)
                    // «Зухр через 7ч 15м в 12:30» шире крыла —
                    // при нехватке места строка равномерно ужимается.
                    .minimumScaleFactor(0.7)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: store.recentCopy?.id)
        }
        .contentShape(Rectangle())
        // Тап открывает home через CGEventTap в IslandPanelController, а
        // не SwiftUI-жестом: жест на этой вью запускал mouse-tracking,
        // который смена режима (.id(mode)) убивала посреди клика вместе
        // с вью — после этого AppKit переставал доставлять окну клики.
        .accessibilityHint("Открыть Aza")
    }

    /// Круглая подложка значка слева — общая для намаза и вспышки копирования.
    private func badge(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: 24, height: 24)
            .background(AzaStyle.acidSurface, in: Circle())
    }

    private func titles(caption: String, title: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(AzaStyle.muted)
                .textCase(.uppercase)
                .tracking(0.5)
                .lineLimit(1)
                .fixedSize()
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? AzaStyle.ink : AzaStyle.muted)
                .lineLimit(1)
                .fixedSize()
        }
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
    @StateObject private var locator = CityLocator()
    /// Календарь выбранного города: экран показывает ЕГО время (времена
    /// намаза уже так отрисованы), поэтому «завтра», шкала суток и оттенок
    /// тоже считаются в таймзоне города, а не устройства.
    private var cityCalendar: Calendar {
        store.prayer.selectedCity?.calendar ?? .current
    }
    /// Общее пространство для скользящей изумрудной таблетки чипов.
    @Namespace private var pillNS

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let next = store.nextPrayerOccurrence(after: context.date)
            let prayers = store.todayPrayers()
            // Последние минуты — те же фазы, что и в компактном режиме:
            // счётчик и шкала теплеют, счётчик мягко пульсирует.
            let phase = PrayerCountdownPhase.make(
                secondsRemaining: next?.date.timeIntervalSince(context.date) ?? .infinity
            )
            let soon = phase != .hidden
            VStack(spacing: 0) {
                NotchRow(reservesNotch: store.hasNotch, notchWidth: store.notchWidth) {
                    // Имя намаза — чернилами, зелёный оставлен иконке и
                    // счётчику: три зелёных пятна в одной строке шумели.
                    HStack(spacing: 7) {
                        // Иконка едва заметно «дышит» в такт свечению героя.
                        Group {
                            let icon = Image(systemName: next?.kind.symbol ?? "clock.badge.questionmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(next == nil ? AzaStyle.muted : AzaStyle.acid)
                            if #available(macOS 15.0, *) {
                                icon.symbolEffect(.breathe.plain, options: .repeat(.continuous))
                            } else {
                                icon
                            }
                        }
                        Text(next?.kind.title ?? "Нет данных")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(next == nil ? AzaStyle.muted : AzaStyle.ink)
                    }
                } right: {
                    let pulseDim = soon && Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0
                    Text(next?.countdown(from: context.date) ?? "—")
                        .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(soon ? AzaStyle.warning : AzaStyle.acid)
                        .opacity(pulseDim ? 0.55 : 1)
                        .animation(.easeInOut(duration: 1), value: pulseDim)
                        .contentTransition(.numericText(countsDown: true))
                }

                HStack(spacing: 14) {
                    // Герой живёт прямо на чёрной сцене, без рамки: одна
                    // карточка справа вместо двух коробок — иерархия
                    // «содержание слева, управление справа» читается сама.
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Следующий намаз")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AzaStyle.muted)
                                .textCase(.uppercase)
                                .tracking(0.8)
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                heroText(next?.time ?? "—")
                                    // Стеклянные цифры: свет сверху, как на
                                    // циферблатах Apple Watch.
                                    .foregroundStyle(next == nil
                                        ? AnyShapeStyle(AzaStyle.muted)
                                        : AnyShapeStyle(LinearGradient(
                                            colors: [AzaStyle.acidSoft, AzaStyle.acid],
                                            startPoint: .top, endPoint: .bottom)))
                                    // Цифры чуть светятся: единственный
                                    // «неоновый» элемент сцены — герой.
                                    .shadow(color: AzaStyle.acid.opacity(next == nil ? 0 : 0.35),
                                            radius: 14)
                                    // Наступил намаз — цифры перелистываются
                                    // мягко, как в часах iOS, а не скачком.
                                    .contentTransition(.numericText())
                                    .animation(.easeInOut(duration: 0.5), value: next?.time)
                                    // Одиночный блик пробегает по цифрам,
                                    // когда остров раскрылся.
                                    .overlay(ShineSweep().mask(heroText(next?.time ?? "—")))
                                Text(next?.kind.title ?? "Нет данных")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(AzaStyle.muted)
                                // После иши «03:56 Фаджр» без пометки читается
                                // как сегодняшний — а он уже завтрашний.
                                if let next,
                                   !cityCalendar.isDate(next.date, inSameDayAs: context.date) {
                                    Text("завтра")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(AzaStyle.faint)
                                }
                            }
                            // Ближайший намаз из другого источника, чем
                            // сетка ниже — говорим об этом прямо.
                            if let other = store.differingSourceLabel(for: next) {
                                Text("источник: \(other)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(AzaStyle.warning)
                            }
                            if let reason = store.prayerUnavailableReason {
                                Text(reason)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(AzaStyle.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Spacer(minLength: 6)

                        HStack(spacing: 5) {
                            ForEach(prayers, id: \.kind) { prayer in
                                PrayerTimeCell(
                                    prayer: prayer,
                                    isNext: next?.date == prayer.date,
                                    isPast: prayer.date < context.date,
                                    now: context.date,
                                    pillNS: pillNS
                                )
                            }
                        }
                        // Наступил намаз — изумрудная таблетка перетекает
                        // на следующий чип, а не перескакивает.
                        .animation(.easeInOut(duration: 0.6), value: next?.date)

                        // Шкала — карта суток от полуночи до полуночи,
                        // светящаяся головка — «сейчас».
                        if next != nil {
                            let cal = cityCalendar
                            let dayStart = cal.startOfDay(for: context.date)
                            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86400)
                            let dayLength = dayEnd.timeIntervalSince(dayStart)
                            let fraction = min(1, max(0, context.date.timeIntervalSince(dayStart) / dayLength))
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(AzaStyle.control)
                                    Capsule()
                                        .fill(soon ? AzaStyle.warning : AzaStyle.acid)
                                        .frame(width: max(3, geo.size.width * fraction))
                                    Circle()
                                        .fill(soon ? AzaStyle.warning : AzaStyle.acid)
                                        .frame(width: 7, height: 7)
                                        .shadow(color: (soon ? AzaStyle.warning : AzaStyle.acid).opacity(0.8),
                                                radius: 4)
                                        .offset(x: min(geo.size.width - 7, max(0, geo.size.width * fraction - 3.5)))
                                }
                            }
                            .frame(height: 3)
                            .padding(.top, 9)
                            .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 6)
                    .padding(.vertical, 2)
                    // Мягкое изумрудное дыхание за героем — глубина без
                    // единой новой рамки. Клип силуэта не даст ему вылезти.
                    .background(BreathingGlow(tint: glowTint(at: context.date)),
                                alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Местоположение")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AzaStyle.muted)
                                .textCase(.uppercase)
                                .tracking(0.8)
                            Spacer()
                            // Иконку в строке меню можно скрыть, и тогда
                            // остров — единственное место выхода. Кнопка в
                            // углу, тихая: краснеет только под курсором.
                            ExitButton(hovering: store.homeHoverZone == .exit)
                        }
                        .padding(.bottom, 8)
                        HStack(spacing: 8) {
                            // Стрелка — отдельная кнопка: один клик подбирает
                            // ближайший городской профиль по геопозиции.
                            Button {
                                Task {
                                    if let match = await locator.locate() {
                                        store.prayer.selectedCityID = match.city.id
                                    }
                                }
                            } label: {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(locator.state == .locating ? AzaStyle.acid : AzaStyle.ink)
                                    .symbolEffect(.pulse, isActive: locator.state == .locating)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(locator.state == .locating)
                            .help("Определить город по геопозиции")
                            // Реальный клик приходит нотификацией из
                            // ручного хит-теста (зона .geo), не в Button.
                            .onReceive(NotificationCenter.default
                                .publisher(for: .azaLocateCity)) { _ in
                                guard locator.state != .locating else { return }
                                Task {
                                    if let match = await locator.locate() {
                                        store.prayer.selectedCityID = match.city.id
                                    }
                                }
                            }

                            // Город кликабелен: настройки открываются сразу
                            // на разделе «Намаз» с выбором города.
                            Button {
                                store.dismissIsland()
                                store.openSetup()
                                NotificationCenter.default.post(
                                    name: .azaShowPrayerSettings, object: nil)
                            } label: {
                                HStack(spacing: 5) {
                                    Text(store.prayer.selectedCity?.name ?? "Город не выбран")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(AzaStyle.ink)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(AzaStyle.faint)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Сменить город")
                        }

                        // Итог геопоиска: честно «ближайший профиль из
                        // списка», отказ или ошибка — прямо под городом.
                        switch locator.state {
                        case let .found(_, distance):
                            Text("ближайший профиль · \(distance) км")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AzaStyle.faint)
                                .padding(.top, 6)
                        case .denied:
                            Text("Геолокация запрещена — выберите вручную")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AzaStyle.warning)
                                .padding(.top, 6)
                        case let .failed(message):
                            Text(message)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AzaStyle.warning)
                                .lineLimit(2)
                                .padding(.top, 6)
                        default:
                            EmptyView()
                        }
                        // Капсула подписывает СЕГОДНЯШНЮЮ сетку. Раньше
                        // она брала источник ближайшего намаза — а он
                        // после иши уже завтрашний и на границе покрытия
                        // приходит из другого источника.
                        Text(store.prayerSourceLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AzaStyle.acid)
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(AzaStyle.control, in: Capsule())
                            .help(store.prayer.source?.caveat ?? store.prayerSourceLabel)
                            .padding(.top, 8)
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            // Запускает фиксированную запись (стоп —
                            // сочетание, Пробел, Enter или кнопка ■);
                            // остров сам перейдёт в режим диктовки по
                            // состоянию контроллера. Раньше кнопка лишь
                            // переключала вид: волна и REC без записи.
                            ActionButton("Диктовка", symbol: "mic",
                                         hovering: store.homeHoverZone == .dictation) {
                                azaDebugLog("Aza: BUTTON Диктовка fired")
                                store.dictation.startLatchedFromUI()
                            }
                            ActionButton("Буфер", symbol: "clipboard",
                                         hovering: store.homeHoverZone == .clipboard) {
                                azaDebugLog("Aza: BUTTON Буфер fired")
                                store.mode = .clipboard
                            }
                            ActionButton("Настройки", symbol: "gearshape",
                                         hovering: store.homeHoverZone == .settings) {
                                azaDebugLog("Aza: BUTTON Настройки fired")
                                // Остров — панель без фокуса, поэтому окно
                                // настройки открывает и активирует само себя.
                                store.dismissIsland()
                                store.openSetup()
                            }
                        }
                    }
                    .frame(width: 238, alignment: .leading)
                    .padding(16)
                    // Карточка — стекло из дизайн-системы.
                    .background(
                        AzaStyle.glass,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(AzaStyle.glassEdge)
                    )
                }
                .frame(height: 166)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
        }
    }

    /// Цифры героя: один и тот же Text служит и глифами, и маской блика.
    private func heroText(_ time: String) -> Text {
        Text(time)
            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
            .fontWidth(.condensed)
    }

    /// Оттенок «дыхания» по времени суток: утро прохладнее, вечер теплее,
    /// ночь — глубокая бирюза. Сдвиги мягкие, изумруд остаётся основой.
    private func glowTint(at date: Date) -> Color {
        switch cityCalendar.component(.hour, from: date) {
        case 4..<11: Color(red: 64 / 255, green: 215 / 255, blue: 170 / 255)
        case 11..<16: AzaStyle.acid
        case 16..<21: Color(red: 150 / 255, green: 205 / 255, blue: 85 / 255)
        default: Color(red: 45 / 255, green: 175 / 255, blue: 185 / 255)
        }
    }
}

/// Одиночная световая полоса, пробегающая слева направо после появления
/// вида; используется маской по цифрам героя. При «уменьшении движения»
/// блика нет.
private struct ShineSweep: View {
    @State private var travel: CGFloat = -0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            if !reduceMotion {
                LinearGradient(
                    colors: [.clear, .white.opacity(0.55), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.5)
                .offset(x: geo.size.width * travel)
                .onAppear {
                    // Задержка — чтобы блик шёл ПОСЛЕ приземления панели,
                    // а не во время полёта из выреза.
                    withAnimation(.easeInOut(duration: 0.9).delay(0.45)) {
                        travel = 1.0
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Изумрудное дыхание за героем: медленный пульс яркости и масштаба в
/// ритме спокойного вдоха-выдоха. При «уменьшении движения» свет статичен.
private struct BreathingGlow: View {
    var tint: Color = AzaStyle.acid
    @State private var breathes = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(tint.opacity(breathes ? 0.10 : 0.055))
            .frame(width: 320, height: 320)
            .blur(radius: 70)
            .scaleEffect(breathes ? 1.08 : 0.94)
            .offset(x: -70, y: -40)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 4).repeatForever(autoreverses: true),
                value: breathes
            )
            .onAppear { breathes = !reduceMotion }
            .onChange(of: reduceMotion) { _, value in breathes = !value }
            .accessibilityHidden(true)
    }
}

private struct PrayerTimeCell: View {
    let prayer: PrayerOccurrence
    let isNext: Bool
    let isPast: Bool
    let now: Date
    let pillNS: Namespace.ID

    @State private var hovering = false

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
        // Прошедшее гаснет и теряет подложку, будущее — мягкие чипы,
        // следующий — единственное залитое акцентом пятно: строка читается
        // как таймлайн «где мы в сутках» без единой рамки. Под курсором
        // чип оживает и в подсказке говорит, сколько до него осталось.
        .foregroundStyle(isNext ? Color.black
                         : isPast ? AzaStyle.muted.opacity(hovering ? 1 : 0.6)
                         : AzaStyle.ink)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isNext || (isPast && !hovering) ? Color.clear
                      : hovering ? AzaStyle.control : AzaStyle.panel)
            if isNext {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AzaStyle.acid)
                    .matchedGeometryEffect(id: "nextPill", in: pillNS)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: AzaMotion.micro), value: hovering)
        .help(hint)
        .accessibilityLabel("\(prayer.kind.title), \(prayer.time)")
        .accessibilityAddTraits(isNext ? .isSelected : [])
    }

    private var hint: String {
        guard !isPast else { return "\(prayer.kind.title) прошёл в \(prayer.time)" }
        let minutes = max(0, Int(prayer.date.timeIntervalSince(now)) / 60)
        let left = minutes >= 60 ? "\(minutes / 60)ч \(minutes % 60)м" : "\(minutes)м"
        return "\(prayer.kind.title) через \(left)"
    }
}

private struct DictationIslandView: View {
    @ObservedObject var store: IslandStore

    /// Отпустили клавишу — запись кончилась, идёт распознавание: волна и
    /// кнопка стоп в этот момент врут (стоп вообще не работает вне записи).
    private var isTranscribing: Bool { store.dictation.state == .transcribing }

    var body: some View {
        NotchRow(reservesNotch: store.hasNotch, notchWidth: store.notchWidth,
                 height: store.hasNotch ? store.notchHeight : 40,
                 horizontalPadding: 16) {
            HStack(spacing: 14) {
                if isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AzaStyle.acid)
                    // Запись кончилась раньше, чем поднялась модель:
                    // честно говорим, чего ждём; сообщение уходит само,
                    // когда модель загрузится и начнётся распознавание.
                    Text(store.dictation.isAwaitingModel
                         ? "Загружаю модель распознавания…" : "Распознаю…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AzaStyle.ink)
                } else {
                    // Запись — красная: универсальный язык REC, зелёная
                    // точка читалась как «всё ок», а не «идёт запись».
                    Circle().fill(AzaStyle.danger).frame(width: 12, height: 12)
                    WaveformView()
                }
            }
        } right: {
            HStack(spacing: 14) {
                // Язык и таймер — одной базовой линией: раньше таймер
                // 11 pt плавал по центру фиксированной колонки и терялся.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(store.dictation.activeLanguage.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AzaStyle.muted)
                    Text(isTranscribing ? "" : store.dictation.elapsedText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(AzaStyle.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 90, alignment: .trailing)
                if !isTranscribing, store.dictation.isLatched {
                    Button { store.dictation.stopFromUI() } label: {
                        Image(systemName: "square")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .foregroundStyle(AzaStyle.ink)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 20, height: 20)
                }
            }
            .frame(width: 124)
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
                    .fill(index.isMultiple(of: 2)
                          ? AzaStyle.danger
                          : AzaStyle.danger.opacity(0.45))
                    .frame(width: 4, height: heights[index])
                    // Неоновое свечение каждого бара: тень цвета записи
                    // дышит вместе с анимацией высоты (идея из ClickUp).
                    .shadow(color: AzaStyle.danger.opacity(0.25), radius: 3)
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
        // Мягкая задняя подсветка позади волны — размытое пятно цвета
        // записи, как у ClickUp: волна будто светится изнутри острова.
        .background(
            Ellipse()
                .fill(AzaStyle.danger.opacity(0.1))
                .blur(radius: 14)
                .scaleEffect(x: 1.5, y: 1.9)
        )
        .onAppear { animates = !reduceMotion }
        .onChange(of: reduceMotion) { _, value in animates = !value }
    }
}

private struct ClipboardIslandView: View {
    @ObservedObject var store: IslandStore
    /// Множественное выделение для ⌘A: локальное состояние вида.
    @State private var selectedIDs: Set<ClipEntry.ID> = []
    @State private var confirmMassDelete = false
    @State private var query = ""
    /// Клавиатура (стрелки, Delete, Esc) работает только пока контейнер
    /// в фокусе — держим его там при открытии и после клика по карточке.
    @FocusState private var listFocused: Bool
    /// Общее пространство изумрудной таблетки «История/Избранное»: при
    /// переключении она перетекает, как у чипов намаза в большом острове.
    @Namespace private var sectionNS

    private var visibleEntries: [ClipEntry] {
        store.visibleEntries(matching: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            NotchRow(reservesNotch: store.hasNotch, notchWidth: store.notchWidth, height: 60, horizontalPadding: 28) {
                HStack(spacing: 6) {
                    SectionButton("История", width: 86, active: store.section == .history,
                                  pillNS: sectionNS) {
                        store.section = .history
                    }
                    SectionButton("Избранное", width: 98, active: store.section == .favorites,
                                  pillNS: sectionNS) {
                        store.section = .favorites
                    }
                    SectionButton("Диктовка", width: 92, active: store.section == .transcripts,
                                  pillNS: sectionNS) {
                        store.section = .transcripts
                    }
                }
                // Таблетка перетекает между разделами, а не перескакивает.
                .animation(.easeOut(duration: AzaMotion.compact),
                           value: store.section)
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
                .background(AzaStyle.glass, in: Capsule())
                .overlay(Capsule().stroke(AzaStyle.glassEdge))
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(visibleEntries) { entry in
                            ClipboardCard(
                                entry: entry,
                                selected: store.selectedID == entry.id,
                                select: {
                                    selectedIDs = []
                                    confirmMassDelete = false
                                    store.selectedID = entry.id
                                    listFocused = true
                                },
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
        .focusEffectDisabled()
        .focused($listFocused)
        .onAppear {
            listFocused = true
            // При открытии сразу выделена последняя скопированная запись:
            // Enter вставляет её без лишних движений (список — от новых).
            store.selectedID = visibleEntries.first?.id
        }
        .onKeyPress { press in
            // ⌘A + Delete — массовое удаление найденного (спец. §8.7).
            // Выделение живёт в этом виде: хранилищу знать о нём незачем.
            if NSApplication.shared.currentEvent?.keyCode == UInt16(kVK_ANSI_A),
               press.modifiers.contains(.command) {
                selectedIDs = Set(visibleEntries.map(\.id))
                confirmMassDelete = false
                return .handled
            }
            // Backspace и Forward Delete ловятся по keyCode: SwiftUI не
            // всегда маппит их на KeyEquivalent.delete в onKeyPress.
            let keyCode = NSApplication.shared.currentEvent?.keyCode
            if keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete) {
                deleteSelection()
                return .handled
            }
            switch press.key {
            case .leftArrow:
                selectedIDs = []
                confirmMassDelete = false
                store.moveSelection(by: -1, in: visibleEntries)
                return .handled
            case .rightArrow:
                selectedIDs = []
                confirmMassDelete = false
                store.moveSelection(by: 1, in: visibleEntries)
                return .handled
            case .return:
                if let id = store.selectedID {
                    store.reuse(id)
                }
                return .handled
            case .escape:
                // Escape снимает сначала подтверждение, потом выделение,
                // потом поиск и лишь затем закрывает остров.
                if confirmMassDelete { confirmMassDelete = false }
                else if !selectedIDs.isEmpty { selectedIDs = [] }
                else if !query.isEmpty { query = "" }
                else { store.mode = .idle }
                return .handled
            default:
                return .ignored
            }
        }
        // Страховка: если onKeyPress событие Delete не получил, оно дойдёт
        // командой deleteBackward по цепочке ответчиков.
        .onDeleteCommand { deleteSelection() }
        .onChange(of: query) { _, _ in
            selectedIDs = []
            confirmMassDelete = false
        }
        .onChange(of: store.selectedID) { _, _ in
            selectedIDs = []
            confirmMassDelete = false
        }
        .onChange(of: visibleEntries.map(\.id)) { old, ids in
            selectedIDs = []
            confirmMassDelete = false
            // Выделение не пропадает: удалённую запись сменяет соседняя
            // (то же место в списке), а на пустом выделении берётся свежая.
            if let selectedID = store.selectedID {
                if !ids.contains(selectedID) {
                    let index = old.firstIndex(of: selectedID) ?? 0
                    store.selectedID = ids.indices.contains(index) ? ids[index] : ids.last
                }
            } else {
                store.selectedID = ids.first
            }
        }
        .overlay(alignment: .top) {
            // Массовое выделение и подтверждение видны пользователю:
            // молчаливое ожидание второго Delete было бы ловушкой.
            if !selectedIDs.isEmpty {
                let deletable = visibleEntries
                    .filter { selectedIDs.contains($0.id) && !$0.favorite }
                    .count
                Text(confirmMassDelete
                     ? "Удалить \(deletable)? Нажмите Delete ещё раз, Esc — отмена"
                     : "Выбрано: \(selectedIDs.count) · Delete — удалить, Esc — снять")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(confirmMassDelete ? AzaStyle.danger : AzaStyle.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(AzaStyle.deep, in: Capsule())
                    .overlay(Capsule().stroke(AzaStyle.glassEdge))
                    .padding(.top, 6)
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
                    .background(AzaStyle.glass, in: Capsule())
                    .overlay(Capsule().stroke(AzaStyle.glassEdge))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
            }
        }
    }

    private func deleteSelection() {
        if selectedIDs.isEmpty {
            if let id = store.selectedID { store.delete(id) }
        } else if confirmMassDelete {
            // Массовое удаление требует подтверждения (§8.7).
            store.commands.deleteAll(visibleEntries.filter { selectedIDs.contains($0.id) })
            selectedIDs = []
            confirmMassDelete = false
        } else {
            confirmMassDelete = true
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: entry.islandKind.symbol)
                Text(entry.islandKind.title).lineLimit(1)
                Spacer()
                Text(ElapsedTime.short(since: entry.createdAt))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let image = entry.thumbnailImage {
                // Как в Paste: превью занимает всю карточку под шапкой от
                // края до края, подпись источника лежит поверх на затемнении.
                // Color.clear задаёт размер ячейки, а картинка живёт в
                // overlay — так scaledToFill не раздувает вёрстку.
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .overlay(alignment: .bottom) {
                        footer(onImage: true)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 8)
                            .background(LinearGradient(
                                colors: [.clear, .black.opacity(0.6)],
                                startPoint: .top, endPoint: .bottom
                            ))
                    }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if entry.islandKind == .files {
                        VStack(spacing: 7) {
                            Image(systemName: "doc.on.doc.fill").font(.system(size: 28))
                            Text(entry.text).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(AzaStyle.ink)
                    } else {
                        // Длинный текст должен читаться в превью: мелкий
                        // кегль и столько строк, сколько влезает в карточку.
                        Text(entry.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AzaStyle.ink)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    footer(onImage: false)
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 206, height: 142)
        // Стекло, как у карточки управления в большом острове: градиент
        // поверхности и кромка, освещённая сверху, вместо плоской рамки.
        .background(AzaStyle.glass)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AzaStyle.acidSoft, lineWidth: 2)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AzaStyle.glassEdge)
            }
        }
        .shadow(color: selected ? AzaStyle.acid.opacity(0.2)
                : hovering ? Color.black.opacity(0.45) : .clear,
                radius: selected ? 18 : 10, y: 6)
        // Под курсором карточка чуть приподнимается — тот же жест, что у
        // чипов намаза.
        .scaleEffect(hovering && !selected ? 1.02 : 1)
        .animation(.easeOut(duration: AzaMotion.micro), value: hovering)
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

    private func footer(onImage: Bool) -> some View {
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
        .foregroundStyle(onImage ? .white : AzaStyle.muted)
    }
}

/// Панель фраз (hold-режим): пока сочетание удерживается, две колонки по
/// пять фраз; вставляет клик или цифра 1…0 с теми же модификаторами.
/// Панель не становится ключевой — каретка остаётся в поле пользователя.
private struct PhrasesIslandView: View {
    @ObservedObject var store: IslandStore
    @ObservedObject private var phraseStore = PhraseStore.shared

    var body: some View {
        VStack(spacing: 0) {
            NotchRow(reservesNotch: store.hasNotch, notchWidth: store.notchWidth,
                     height: 54, horizontalPadding: 28) {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AzaStyle.acid)
                        .frame(width: 24, height: 24)
                        .background(AzaStyle.acidSurface, in: Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Быстрая вставка")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(AzaStyle.muted)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Text("Фразы")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AzaStyle.ink)
                    }
                }
            } right: {
                HStack(spacing: 10) {
                    // Две короткие строки: одна длинная упиралась в вырез.
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("цифра или клик — вставить")
                        Text("с ⇧ — второй вариант")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AzaStyle.muted)
                    .lineLimit(1)
                    .fixedSize()
                    EditPhrasesButton {
                        store.dismissIsland()
                        store.openSetup()
                        NotificationCenter.default.post(
                            name: .azaShowPhraseSettings, object: nil)
                    }
                }
            }

            HStack(alignment: .top, spacing: 12) {
                phraseColumn(0..<5)
                phraseColumn(5..<10)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 18)
        }
    }

    private func phraseColumn(_ range: Range<Int>) -> some View {
        VStack(spacing: 8) {
            ForEach(range, id: \.self) { index in
                PhraseRow(number: (index + 1) % 10,
                          text: phraseStore.phrases[index],
                          shiftHeld: store.phraseShiftHeld) { alternate in
                    store.insertPhrase(at: index, alternate: alternate)
                }
            }
        }
    }
}

private struct PhraseRow: View {
    let number: Int
    let text: String
    /// ⇧ удерживается: цифры вставят вторые варианты — таблетки горят
    /// и раскрывают полный текст.
    let shiftHeld: Bool
    /// true — вставить второй вариант слота (женская форма, полная фраза).
    let insert: (Bool) -> Void

    @State private var hovering = false
    @State private var altHovering = false

    /// Таблетка «активна» — под курсором или удерживается ⇧: подсветка
    /// и приоритет по ширине, чтобы длинный вариант дочитывался целиком.
    private var altActive: Bool { altHovering || shiftHeld }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Сырая строка слота может держать два варианта через «|» — панель
    /// показывает их раздельно, без служебной черты: основной текст и
    /// кликабельная таблетка «⇧ …» со вторым вариантом.
    private var main: String { PhraseStore.variant(text, alternate: false) }
    private var alt: String? {
        let alt = PhraseStore.variant(text, alternate: true)
        return alt == main ? nil : alt
    }

    var body: some View {
        HStack(spacing: 10) {
            // Основная зона: весь ряд, кроме таблетки. ⇧-клик тоже даёт
            // второй вариант — для тех, кто привык к клавише.
            Button {
                insert(NSEvent.modifierFlags.contains(.shift))
            } label: {
                HStack(spacing: 10) {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(hovering && !isEmpty && !altActive
                                         ? Color.black : AzaStyle.acid)
                        .frame(width: 22, height: 22)
                        .background(hovering && !isEmpty && !altActive
                                    ? AzaStyle.acid : AzaStyle.acidSurface,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(isEmpty ? "—" : main)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isEmpty ? AzaStyle.faint : AzaStyle.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            // Активная таблетка отбирает ширину: полный текст второго
            // варианта важнее основного, который пользователь уже знает.
            .layoutPriority(altActive ? 0 : 1)
            .accessibilityLabel("Фраза \(number): \(main)")

            if let alt {
                Button { insert(true) } label: {
                    HStack(spacing: 5) {
                        Text("⇧")
                            .font(.system(size: 9, weight: .bold))
                        Text(alt)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .foregroundStyle(altActive ? Color.black : AzaStyle.muted)
                    .background(altActive ? AnyShapeStyle(AzaStyle.acid)
                                          : AnyShapeStyle(AzaStyle.glass),
                                in: Capsule())
                    .overlay(Capsule().stroke(altActive
                             ? AnyShapeStyle(AzaStyle.acidSoft)
                             : AnyShapeStyle(AzaStyle.glassEdge)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .layoutPriority(altActive ? 1 : 0)
                .onHover { altHovering = $0 }
                .help(alt)
                .accessibilityLabel("Фраза \(number), второй вариант: \(alt)")
            }

            Spacer(minLength: 0)
            // Стрелка-подсказка «вставится в текст» — только под
            // курсором, чтобы десять рядов не рябили.
            if hovering, !isEmpty {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AzaStyle.acid)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(AzaStyle.glass,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(hovering && !isEmpty && !altActive
                    ? AnyShapeStyle(AzaStyle.acidSoft)
                    : AnyShapeStyle(AzaStyle.glassEdge)))
        // Под курсором ряд чуть приподнимается — тот же жест, что у
        // карточек буфера и чипов намаза.
        .scaleEffect(hovering && !isEmpty ? 1.015 : 1)
        .shadow(color: hovering && !isEmpty ? .black.opacity(0.35) : .clear,
                radius: 8, y: 4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: AzaMotion.micro), value: hovering)
        .animation(.easeOut(duration: AzaMotion.micro), value: altActive)
    }
}

/// Кнопка «Изменить» в шапке панели фраз: ведёт в настройки сразу на
/// раздел «Фразы».
private struct EditPhrasesButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                Text("Изменить")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(hovering ? AzaStyle.ink : AzaStyle.muted)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(hovering ? AzaStyle.control : AzaStyle.panel, in: Capsule())
            .overlay(Capsule().stroke(AzaStyle.glassEdge))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: AzaMotion.micro), value: hovering)
        .help("Открыть настройки фраз")
    }
}

/// Кнопки действий — один нейтральный стиль на всех: зелёный в этом окне
/// зарезервирован за намазом, а разноцветные круги (синий, зелёный, серый)
/// спорили друг с другом. Акцент появляется под курсором.
private struct ActionButton: View {
    let title: String
    let symbol: String
    // Hover приходит снаружи (IslandPanelController опрашивает курсор):
    // .onHover в расширенной панели мёртв — mouseMoved до неё не доходит.
    let hovering: Bool
    let action: () -> Void

    init(_ title: String, symbol: String, hovering: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.hovering = hovering
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(hovering ? AzaStyle.acid : AzaStyle.ink)
                    .background(hovering ? AzaStyle.acidSurface : AzaStyle.control, in: Circle())
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? AzaStyle.ink : AzaStyle.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: AzaMotion.micro), value: hovering)
    }
}

private struct ExitButton: View {
    let hovering: Bool

    var body: some View {
        Button("Выход") { NSApp.terminate(nil) }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovering ? AzaStyle.danger : AzaStyle.faint)
            .animation(.easeOut(duration: AzaMotion.micro), value: hovering)
    }
}

private struct SectionButton: View {
    let title: String
    let width: CGFloat
    let active: Bool
    let pillNS: Namespace.ID
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, width: CGFloat, active: Bool, pillNS: Namespace.ID,
         action: @escaping () -> Void) {
        self.title = title
        self.width = width
        self.active = active
        self.pillNS = pillNS
        self.action = action
    }

    var body: some View {
        // Кадр и contentShape ВНУТРИ label: у Button(title) кликабелен
        // только текст, клик по телу пилюли уходил в пустоту.
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Color.black
                                 : hovering ? AzaStyle.ink : AzaStyle.muted)
                .frame(width: width, height: 32)
                .contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .background {
                if active {
                    Capsule().fill(AzaStyle.acid)
                        .matchedGeometryEffect(id: "sectionPill", in: pillNS)
                } else {
                    Capsule().fill(hovering ? AzaStyle.control : AzaStyle.panel)
                    Capsule().stroke(AzaStyle.glassEdge)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: AzaMotion.micro), value: hovering)
    }
}

