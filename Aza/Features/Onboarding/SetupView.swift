import AVFoundation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Настройка и состояние разрешений (§9) в дизайн-системе Aza.
///
/// Группы настроек соответствуют задачам, а пояснения доступны без наведения.
extension Notification.Name {
    /// Просьба открыть настройки сразу на разделе «Намаз» (клик по городу
    /// в острове).
    static let azaShowPrayerSettings = Notification.Name("aza.showPrayerSettings")
    /// Просьба открыть настройки на разделе «Фразы» (кнопка «Изменить»
    /// в панели фраз).
    static let azaShowPhraseSettings = Notification.Name("aza.showPhraseSettings")
    /// Клик по гео-стрелке в home-острове: определить город по геопозиции
    /// (клики до SwiftUI не доходят — команда идёт из ручного хит-теста).
    static let azaLocateCity = Notification.Name("aza.locateCity")
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @AppStorage(PrayerStore.cityStorageKey) private var cityID = ""
    @AppStorage(PrayerNotifications.soundStorageKey) private var prayerSound =
        PrayerNotifications.Sound.system.rawValue
    @StateObject private var soundPreview = PrayerSoundPreview()
    @AppStorage(DictationController.profileStorageKey) private var profile = "balanced"
    @AppStorage(OmniASR.variantStorageKey) private var omniVariant = "ctc"
    @StateObject private var locator = CityLocator()
    @AppStorage(ChechenAutocorrect.layoutStorageKey) private var layoutCorrection = false
    @AppStorage(ChechenAutocorrect.typoStorageKey) private var typoCorrection = false
    @AppStorage(ChechenAutocorrect.ambiguityStorageKey) private var ambiguityAbstention = true
    @AppStorage(ChechenAutocorrect.latinizationStorageKey) private var latinization = false
    @AppStorage(PasteboardMonitor.storageKey) private var clipboardHistoryEnabled = true
    @AppStorage(ClipboardStore.retentionKey) private var retentionDays = 30
    @AppStorage(IslandStore.copyFlashKey) private var copyFlash = true
    @AppStorage(IslandStore.copySoundKey) private var copySound = ""
    @AppStorage(IslandStore.compactModeKey) private var islandMode = "auto"
    @AppStorage(AzaApp.menuBarIconKey) private var menuBarIconVisible = true
    @AppStorage(MenuBarDisplay.storageKey) private var menuBarDisplay = MenuBarDisplay.logo
    @State private var dictationHotKey = HotKeyBinding.load(
        HotKeyBinding.dictationKey, fallback: .dictationDefault)
    @State private var omniHotKey = HotKeyBinding.load(
        HotKeyBinding.omniDictationKey, fallback: .omniDictationDefault)
    @State private var clipboardHotKey = HotKeyBinding.load(
        HotKeyBinding.clipboardKey, fallback: .clipboardDefault)
    @State private var phrasesHotKey = HotKeyBinding.load(
        HotKeyBinding.phrasesKey, fallback: .phrasesDefault)
    @ObservedObject private var phraseStore = PhraseStore.shared
    /// Необратимые действия подтверждаются отдельным системным диалогом.
    @State private var confirmPhraseReset = false
    @State private var confirmHistoryClear = false
    /// Ошибка удаления модели; заодно любое изменение перечитывает
    /// isModelCached с диска при перерисовке.
    @State private var modelDeleteError: String?
    @AppStorage(DictationController.languageStorageKey) private var dictationLanguage = "auto"
    @AppStorage(DictationController.unloadTimeoutStorageKey) private var unloadMinutes = 30
    @AppStorage(DictationController.removeFillersStorageKey) private var removeFillers = true
    @AppStorage(DictationController.streamingStorageKey) private var streamingDictation = true
    @AppStorage(DictationController.customWordsStorageKey) private var dictationCustomWords = ""
    @AppStorage(DictationController.toneVolumeStorageKey) private var toneVolume =
        DictationController.toneVolumeDefault
    @AppStorage(DictationController.toneSetStorageKey) private var toneSet =
        DictationController.ToneSet.marimba.rawValue
    @State private var tonePreviewTask: Task<Void, Never>?
    /// Второстепенные редакторы открываются поверх текущего раздела.
    @State private var showDataSheet = false
    @State private var showAppsSheet = false
    @State private var showExceptionWords = false
    @State private var showPrayerNotifSheet = false
    /// Характеристики этого Mac — под них подбирается рекомендация.
    private let capabilities = MacCapabilities.current()

    /// Настройки сгруппированы по задачам; сочетания остаются рядом со своей функцией.
    private enum Section: String, CaseIterable {
        case general, permissions, dictation, correction, clipboard, phrases, prayer

        var title: String {
            switch self {
            case .general: "Общее"
            case .permissions: "Доступ и данные"
            case .dictation: "Диктовка"
            case .correction: "Автозамена"
            case .clipboard: "Буфер обмена"
            case .phrases: "Фразы"
            case .prayer: "Намаз"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "Запуск Aza и поведение острова на экране."
            case .permissions: "Доступ к функциям macOS, исключения и локальные данные."
            case .dictation: "Превращайте речь в текст прямо на этом Mac."
            case .correction: "Исправляйте раскладку и опечатки во время набора."
            case .clipboard: "Возвращайтесь к скопированному и управляйте историей."
            case .phrases: "Частые ответы и приветствия — одним сочетанием."
            case .prayer: "Расписание вашего города и напоминания о намазе."
            }
        }

        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .permissions: "lock.shield"
            case .dictation: "mic"
            case .correction: "keyboard"
            case .clipboard: "doc.on.clipboard"
            case .phrases: "text.bubble"
            case .prayer: "moon.stars"
            }
        }
    }

    @State private var section: Section = .general
    @State private var returnToGuide = false

    var body: some View {
        Group {
            if model.showsOnboarding {
                OnboardingView(model: model, progress: model.onboarding) { step in
                    section = Section(rawValue: step.rawValue) ?? .general
                    returnToGuide = true
                    model.showsOnboarding = false
                }
            } else {
                HStack(spacing: 0) {
                    sidebar
                    content
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 820, maxWidth: .infinity,
               minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .background(AzaStyle.stage)
        .tint(AzaStyle.rise)
        .preferredColorScheme(.dark)
        // Закрыли настройки — прослушивание смолкло. Звук, доигрывающий
        // за закрытым окном, пользователь остановить уже не может.
        .onDisappear {
            soundPreview.stop()
            tonePreviewTask?.cancel()
        }
        .onChange(of: model.showsOnboarding) { _, showing in
            if showing { returnToGuide = false }
        }
        // Клик по городу в острове ведёт именно к выбору города, а не к
        // разделу, оставшемуся открытым с прошлого раза.
        .onReceive(NotificationCenter.default.publisher(for: .azaShowPrayerSettings)) { _ in
            model.showsOnboarding = false
            section = .prayer
        }
        .onReceive(NotificationCenter.default.publisher(for: .azaShowPhraseSettings)) { _ in
            model.showsOnboarding = false
            section = .phrases
        }
        // Взведённое «Точно очистить/сбросить» не должно ждать в засаде
        // до следующего визита в раздел.
        .onChange(of: section) { _, _ in
            confirmHistoryClear = false
            confirmPhraseReset = false
            soundPreview.stop()
            tonePreviewTask?.cancel()
        }
        .sheet(isPresented: $showDataSheet) { DataSheet(model: model) }
        .sheet(isPresented: $showAppsSheet) { AppExclusionsSheet() }
        .sheet(isPresented: $showPrayerNotifSheet) {
            PrayerNotificationsSheet(prayer: model.prayer)
        }
    }

    // MARK: Сайдбар и содержимое

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aza").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AzaStyle.ink)
                    Text("Настройки").font(AzaStyle.caption)
                        .foregroundStyle(AzaStyle.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 26)

            sidebarGroup("Приложение", items: [.general, .permissions])
            sidebarGroup("Работа с текстом", items: [.dictation, .correction, .clipboard, .phrases])
            sidebarGroup("Напоминания", items: [.prayer])
            Spacer(minLength: 20)
            Label("Работает на вашем Mac", systemImage: "desktopcomputer")
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.faint)
                .padding(10)
        }
        .padding(12)
        .frame(width: 212)
        .background(AzaStyle.card)
        .overlay(alignment: .trailing) { AzaStyle.line.opacity(0.5).frame(width: 1) }
    }

    private func sidebarGroup(_ title: String, items: [Section]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AzaStyle.faint)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ForEach(items, id: \.self) { sidebarRow($0) }
        }
        .padding(.bottom, 22)
    }

    private func sidebarRow(_ item: Section) -> some View {
        Button {
            section = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.system(size: 12, weight: section == item ? .semibold : .regular))
                Spacer(minLength: 0)
                if item == .permissions, needsPermissions {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .accessibilityLabel("Есть невыданные разрешения")
                }
            }
            .foregroundStyle(section == item ? AzaStyle.ink : AzaStyle.muted)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(section == item ? AzaStyle.control : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                if section == item {
                    Capsule().fill(AzaStyle.rise).frame(width: 3, height: 14)
                        .padding(.leading, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(section == item ? .isSelected : [])
        .accessibilityIdentifier("settings.\(item.rawValue)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(section.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AzaStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(section.subtitle)
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch section {
                    case .general: generalCard
                    case .permissions: permissionsCard
                    case .dictation: dictationCard
                    case .correction: correctionCard
                    case .clipboard: clipboardCard
                    case .phrases: phrasesCard
                    case .prayer: prayerCard
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(section)

            HStack {
                if returnToGuide || !model.onboarding.completed {
                    Button("Продолжить знакомство") { model.showsOnboarding = true }
                        .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
                } else {
                    Text("Изменения сохраняются автоматически")
                        .font(AzaStyle.caption)
                        .foregroundStyle(AzaStyle.faint)
                }
                Spacer(minLength: 8)
                Button("Готово") {
                    NSApp.windows.first { $0.delegate is SetupWindowController }?.performClose(nil)
                }
                .buttonStyle(AzaCapsuleButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { AzaStyle.line.opacity(0.5).frame(height: 1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AzaStyle.stage)
    }

    // MARK: Доступ и данные

    private var permissionsCard: some View {
        Group {
            card("Разрешения macOS") {
                hint("Выдайте доступ только к тем функциям, которыми пользуетесь.")
                divider
                permissionRows
            }
            card("Исключения и хранение") {
                settingRow("Приложения-исключения", detail: "Не исправлять текст и не сохранять скопированное в выбранных приложениях.") {
                    Button("Настроить…") { showAppsSheet = true }
                        .buttonStyle(AzaCapsuleButtonStyle())
                }
                divider
                settingRow("Данные на этом Mac", detail: "Занятое место, история буфера, модели и удаление данных.") {
                    Button("Показать…") { showDataSheet = true }
                        .buttonStyle(AzaCapsuleButtonStyle())
                }
            }
        }
    }

    private var needsPermissions: Bool {
        status(model.notifications) != .granted || status(model.microphone) != .granted
            || !model.axTrusted || !model.inputMonitoring
    }

    @ViewBuilder
    private var permissionRows: some View {
        Group {
            permissionRow(
                "Уведомления", symbol: "bell",
                status: status(model.notifications),
                detail: "Напоминание ко времени намаза.",
                denied: "Включается в Системных настройках → Уведомления"
            ) {
                Button("Разрешить") { Task { await model.requestNotifications() } }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
            }

            divider
            permissionRow(
                "Микрофон", symbol: "mic",
                status: status(model.microphone),
                detail: "Нужен для диктовки; аудио не сохраняется на диск.",
                denied: "Включается в Системных настройках → Микрофон"
            ) {
                Button("Разрешить") { model.requestMicrophone() }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
            }

            divider
            permissionRow(
                "Управление компьютером", symbol: "hand.tap",
                status: model.axTrusted ? .granted : .missing,
                detail: "Вставка текста прямо в поле. Без него текст остаётся в буфере."
            ) {
                Button("Открыть настройки") { model.requestAccessibility() }
                    .buttonStyle(AzaCapsuleButtonStyle())
            }

            divider
            permissionRow(
                "Мониторинг ввода", symbol: "keyboard",
                status: model.inputMonitoring ? .granted : .missing,
                detail: "Нужен для исправления раскладки. Действует после перезапуска Aza."
            ) {
                HStack(spacing: 6) {
                    Button("Разрешить") { model.requestInputMonitoring() }
                        .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
                    Button("Перезапустить") { model.restartApp() }
                        .buttonStyle(AzaCapsuleButtonStyle())
                }
            }
        }
    }

    // MARK: Остальные разделы

    private var prayerCard: some View {
        Group {
            card("Город и расписание") {
                settingRow("Город", detail: "По нему Aza выбирает расписание намаза.") {
                    CityPickerView(cityID: $cityID, cities: model.prayer.allCities)
                        .buttonStyle(AzaCapsuleButtonStyle())
                        .onChange(of: cityID) { _, value in
                            model.prayer.selectedCityID = value.isEmpty ? nil : value
                        }
                }
                Button(locator.state == .locating ? "Определяю город…" : "Определить по геопозиции") {
                    Task {
                        if let match = await locator.locate() {
                            cityID = match.city.id
                            model.prayer.selectedCityID = match.city.id
                        }
                    }
                }
                .buttonStyle(AzaCapsuleButtonStyle())
                .disabled(locator.state == .locating)
                switch locator.state {
                case let .found(id, distance):
                    hint("Ближайший профиль: \(model.prayer.allCities.first { $0.id == id }?.name ?? id) · \(distance) км")
                case let .failed(message): warn(message)
                default: EmptyView()
                }
                if !cityID.isEmpty {
                    divider
                    sourceStatus
                }
            }
            if !cityID.isEmpty {
                card("Напоминания") {
                    settingToggle("Уведомлять о намазе", isOn: Binding(
                        get: { model.prayer.notificationsEnabled },
                        set: { on in Task { await model.prayer.setNotifications(enabled: on) } }
                    ), help: "Напоминания приходят через уведомления macOS.")
                    divider
                    settingRow("Для каждого намаза", detail: "Выберите, о каких намазах напоминать и за сколько минут.") {
                        Button("Настроить…") { showPrayerNotifSheet = true }
                            .buttonStyle(AzaCapsuleButtonStyle())
                            .disabled(!model.prayer.notificationsEnabled)
                    }
                    divider
                    soundPicker
                }
            }
        }
    }

    /// Чем звучит уведомление о намазе. Полная запись длиннее, чем
    /// система разрешает для звука уведомления, — говорим об этом прямо,
    /// а не оставляем пользователя гадать, почему азан обрывается.
    @ViewBuilder
    private var soundPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Короткая подпись: полная «Звук уведомления» не влезает
                // в колонку и обрезалась в «Звук уведо…».
                Text("Звук")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "Чем звучит уведомление о намазе. Кнопка ▶ — прослушать выбранный азан.")
                Spacer(minLength: 8)
                Picker("Звук уведомления о намазе", selection: $prayerSound) {
                    ForEach(PrayerNotifications.Sound.allCases, id: \.rawValue) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 148)
                // Выбрал — сразу услышал. Иначе выбор идёт вслепую, а
                // разница между четырьмя азанами на слух не угадывается.
                .onChange(of: prayerSound) { _, value in
                    guard let option = PrayerNotifications.Sound(rawValue: value) else { return }
                    soundPreview.play(option)
                    // Звук зашит в уже запланированные уведомления —
                    // без пересборки они прозвучат старым звуком.
                    model.prayer.rescheduleNotifications()
                }
                Button {
                    guard let option = PrayerNotifications.Sound(rawValue: prayerSound) else { return }
                    soundPreview.toggle(option)
                } label: {
                    Image(systemName: soundPreview.playing != nil ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(soundPreview.playing != nil ? AzaStyle.rise : AzaStyle.muted)
                .background(AzaStyle.control, in: Circle())
                .overlay(Circle().stroke(AzaStyle.line))
                .help(soundPreview.playing != nil ? "Остановить" : "Прослушать")
                .accessibilityLabel(soundPreview.playing != nil ? "Остановить звук" : "Прослушать звук")
                // У системного звука файла нет — играть нечего.
                .disabled(PrayerNotifications.Sound(rawValue: prayerSound)?.fileName == nil)
            }
            if PrayerNotifications.Sound(rawValue: prayerSound)?.fileName != nil {
                hint("Запись звучит целиком, пока Aza запущена, даже при скрытом баннере. "
                     + "Focus и «Не беспокоить» её не приглушают. Во время диктовки — пауза.")
            }
        }
    }

    /// Модели показываем списком: что доступно, что уже скачано и какая
    /// подходит ЭТОМУ Mac — иначе выбор из трёх слов ничего не объясняет.
    /// Что за времена показаны: выверенная таблица или наш расчёт.
    /// Спецификация §4.3 требует называть источник, а не молчать о нём.
    @ViewBuilder
    private var sourceStatus: some View {
        // Три состояния, а не два. Третье — «времён нет вообще»: у города
        // из официального каталога может не быть координат, и когда день
        // выходит за покрытие таблицы, считать не по чему. Раньше здесь
        // писалось «рассчитано по координатам», хотя расчёта не было.
        let table = model.prayer.hasVerifiedTable
        let unavailable = model.prayer.unavailableReason
        let hasTimes = unavailable == nil
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: !hasTimes ? "exclamationmark.triangle.fill"
                                        : (table ? "checkmark.seal.fill" : "function"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(!hasTimes ? AzaStyle.warning
                                           : AzaStyle.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(!hasTimes ? "Времён на сегодня нет"
                     : table ? "Источник: \(model.prayer.source?.label ?? "расписание")"
                     : "Готового расписания нет — считаем сами")
                    .font(AzaStyle.label)
                    .foregroundStyle(AzaStyle.ink)
                Text(unavailable
                     ?? (table
                         ? "Времена берутся из добавленного расписания."
                         : "Сохранённого расписания для этого города нет, поэтому время рассчитано автоматически по координатам (\(model.prayer.source?.label ?? "расчёт"))."))
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if let caveat = model.prayer.source?.caveat {
                    warn(caveat)
                }
            }
        }
    }

    private var dictationCard: some View {
        Group {
            card("Запуск") {
                HotKeyRecorder(title: "Whisper · русский / English", binding: $dictationHotKey,
                               allowModifierKeys: true,
                               registrationError: model.dictation.hotKeyError) { binding in
                    binding.save(HotKeyBinding.dictationKey,
                                 registering: model.dictation.rebindHotKey)
                }
                .disabled(model.dictation.state != .idle)
                divider
                HotKeyRecorder(title: "OmniASR · чеченский", binding: $omniHotKey,
                               allowModifierKeys: true,
                               registrationError: model.dictation.omniHotKeyError) { binding in
                    binding.save(HotKeyBinding.omniDictationKey) {
                        model.dictation.rebindHotKey(for: .omni)
                    }
                }
                .disabled(model.dictation.state != .idle)
                hint("Удерживайте клавишу нужной модели для записи. Двойное нажатие той же клавиши включает запись без удержания; она же, Пробел или Enter останавливают её. Следующую запись начинайте после вставки текста.")
            }
            card("Распознавание") {
                settingRow("Язык") {
                    Picker("Язык диктовки", selection: $dictationLanguage) {
                        Text("Авто").tag("auto")
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                        Text("Чеченский").tag("ce")
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .disabled(!model.dictation.canChangeEngine)
                    .onChange(of: dictationLanguage) { _, _ in model.dictation.languageChanged() }
                }
                if dictationLanguage == "ce" {
                    hint("Для запуска из меню выбран OmniASR. Клавиша Whisper всё равно запускает Whisper с автоопределением русского / English. Качество чеченской речи пока экспериментальное.")
                } else {
                    hint("Этот язык используется Whisper и запуском из меню. Горячая клавиша OmniASR всегда включает чеченскую модель.")
                }
                divider
                VStack(alignment: .leading, spacing: 8) {
                    settingLabel("Свои слова", detail: "Имена и термины через запятую помогают точнее распознавать речь.")
                    TextField("Например: Ахьмад, Соьлжа-Гӏала", text: $dictationCustomWords)
                        .textFieldStyle(.roundedBorder)
                        .font(AzaStyle.body)
                        .accessibilityLabel("Свои слова для диктовки")
                }
                .disabled(dictationLanguage == "ce")
                divider
                settingToggle("Убирать звуки-паразиты", isOn: $removeFillers,
                              help: "Убирает «эм», «э-э» и “uh”. Слова «ну» и «вот» остаются.")
                    .disabled(dictationLanguage == "ce")
                divider
                settingToggle("Распознавать во время записи", isOn: $streamingDictation,
                              help: "Сокращает ожидание после записи с Whisper. Работает для русского и английского; чеченская речь распознаётся после остановки.")
                    .disabled(dictationLanguage == "auto" || dictationLanguage == "ce")
            }
            card("Whisper · русский и английский") {
                ForEach(Array(DictationController.Profile.allCases.enumerated()), id: \.element) { index, item in
                    if index > 0 { divider }
                    modelRow(item)
                }
                if let modelDeleteError {
                    warn(modelDeleteError)
                }
                hint(capabilities.recommendationReason)

                // Загрузка выбранной модели: кнопка и полоса прогресса —
                // раньше загрузка шла молча при первой диктовке.
                // Полоса живёт только пока идёт скачивание. Ровно 100% —
                // это уже подготовка модели, и полосу надо убрать: иначе она
                // выглядит зависшей всё время прогрева.
                if !model.dictation.isInstallingOmni, let progress = model.dictation.downloadProgress, progress < 0.999 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                            .tint(AzaStyle.rise)
                        Text("Загрузка: \(Int(progress * 100))%")
                            .font(AzaStyle.caption)
                            .foregroundStyle(AzaStyle.faint)
                    }
                } else if !model.dictation.isInstallingOmni, case .loadingModel = model.dictation.state {
                    Text("Готовлю модель…")
                        .font(AzaStyle.caption)
                        .foregroundStyle(AzaStyle.faint)
                } else if let selected = DictationController.Profile(rawValue: profile),
                          !DictationController.isModelCached(selected) {
                    Button("Скачать модель · \(selected.sizeLabel)") {
                        model.dictation.downloadSelectedModel()
                    }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
                    // Скачивание обнуляет модель в памяти — во время диктовки
                    // нельзя, как и удаление (guard дублируется в контроллере).
                    .disabled(!model.dictation.canChangeEngine || dictationLanguage == "ce")
                }
                divider
                HStack {
                    Text("Выгружать модель")
                        .font(AzaStyle.body)
                        .foregroundStyle(AzaStyle.ink)
                    HelpDot(text: "Модель держит сотни мегабайт — гигабайты памяти. После простоя она выгружается; следующая диктовка стартует сразу, но распознавание чуть подождёт её подъёма. «Никогда» — максимум скорости ценой памяти.")
                    Spacer(minLength: 8)
                    // Чтение через валидированный аксессор: чужое значение в
                    // defaults иначе оставляло бы Picker без выбранного пункта,
                    // хотя контроллер уже считает его тридцатью минутами.
                    Picker("Выгружать модель из памяти", selection: Binding(
                        get: { DictationController.unloadMinutes },
                        set: { unloadMinutes = $0 }
                    )) {
                        Text("Через 5 мин").tag(5)
                        Text("Через 30 мин").tag(30)
                        Text("Через час").tag(60)
                        Text("Никогда").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: unloadMinutes) { _, _ in
                        model.dictation.unloadTimeoutChanged()
                    }
                }

            }
            card("Чеченский · OmniASR") {
                let variant = OmniASR.Variant(rawValue: omniVariant) ?? .ctc
                Picker("Вариант OmniASR", selection: $omniVariant) {
                    ForEach(OmniASR.Variant.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!model.dictation.canChangeEngine)
                .onChange(of: omniVariant) { _, _ in model.dictation.languageChanged() }
                hint(variant == .ctc
                     ? "Быстрый вариант. Разрешены только русские и чеченские буквы, цифры и знаки. Ограничение алфавита не гарантирует правильные слова."
                     : "Языковая подсказка: чеченский. Русские буквы тоже разрешены. Этот вариант требует больше памяти и работает медленнее; смешанную речь нужно проверить на своих записях.")
                divider
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(variant.modelName).font(AzaStyle.label)
                        Text(OmniASR.isInstalled(variant) ? "Скачана · работает без интернета" : "\(variant.sizeLabel) + общие компоненты")
                            .font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
                    }
                    Spacer()
                    if model.dictation.isInstallingOmni {
                        Button("Отменить") { model.dictation.cancelOmniDownload() }
                    } else {
                        if !OmniASR.isInstalled(variant) {
                            Button("Скачать") { model.dictation.downloadOmniModel() }
                                .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
                                .disabled(!model.dictation.canChangeEngine || !OmniASR.supported)
                        }
                        if FileManager.default.fileExists(atPath: OmniASR.directory.path) {
                            Button("Удалить OmniASR", role: .destructive) {
                                Task { modelDeleteError = await model.dictation.deleteOmniModel() }
                            }
                            .help("Удаляет оба варианта OmniASR и общие компоненты распознавания")
                            .disabled(!model.dictation.canDeleteModels)
                        }
                    }
                }
                if model.dictation.isInstallingOmni {
                    if let progress = model.dictation.downloadProgress {
                        ProgressView(value: progress).tint(AzaStyle.rise)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Text(model.dictation.status)
                    .font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                    .textSelection(.enabled)
                hint(OmniASR.supported
                     ? "Скачивается только выбранный вариант, по кнопке. Горячая клавиша \(omniHotKey.display) запускает вариант, выбранный выше. Память освобождается после каждой записи; настройка выгрузки выше относится к Whisper."
                     : "Для чеченской модели нужен Mac с Apple Silicon.")
            }
            card("Звуковые сигналы") {
                HStack {
                    Text("Звук сигналов")
                        .font(AzaStyle.body)
                        .foregroundStyle(AzaStyle.ink)
                    HelpDot(text: "Пара звуков начала и конца диктовки: вверх — запись пошла, вниз — распознаю.")
                    Spacer(minLength: 8)
                    Picker("Звук сигналов диктовки", selection: $toneSet) {
                        ForEach(DictationController.ToneSet.allCases, id: \.rawValue) { set in
                            Text(set.title).tag(set.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: toneSet) { _, _ in
                        DictationController.playTone(start: false)
                    }
                }
                divider
                HStack {
                    Text("Громкость сигналов")
                        .font(AzaStyle.body)
                        .foregroundStyle(AzaStyle.ink)
                    HelpDot(text: "Звуки начала и конца диктовки. В нуле — без звука.")
                    Spacer(minLength: 8)
                    Image(systemName: toneVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AzaStyle.muted)
                        .frame(width: 16)
                    Slider(value: $toneVolume, in: 0...1)
                        .accessibilityLabel("Громкость сигналов диктовки")
                        .controlSize(.small)
                        .tint(AzaStyle.rise)
                        .frame(width: 140)
                        // Отпустили бегунок — проигрываем сигнал на новой
                        // громкости, чтобы её можно было подобрать на слух.
                        .onChange(of: toneVolume) { _, _ in
                            tonePreviewTask?.cancel()
                            tonePreviewTask = Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                guard !Task.isCancelled else { return }
                                DictationController.playTone(start: false)
                            }
                        }
                }
            }
        }
    }

    private func modelRow(_ item: DictationController.Profile) -> some View {
        let isSelected = profile == item.rawValue
        let isRecommended = capabilities.recommendedProfile == item
        let isDownloaded = DictationController.isModelCached(item)
        let tooHeavy = !capabilities.canRun(item)

        return HStack(alignment: .top, spacing: 8) {
            Button {
                profile = item.rawValue
                model.dictation.profileChanged()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? AzaStyle.rise : AzaStyle.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(AzaStyle.label)
                                .foregroundStyle(AzaStyle.ink)
                            if isRecommended {
                                tag("Для этого Mac", color: AzaStyle.muted,
                                    background: AzaStyle.control)
                            }
                            if isDownloaded {
                                tag("Скачана", color: AzaStyle.faint,
                                    background: AzaStyle.control)
                            }
                        }
                        Text(item.summary)
                            .font(AzaStyle.caption)
                            .foregroundStyle(tooHeavy ? AzaStyle.warning : AzaStyle.faint)
                            .fixedSize(horizontal: false, vertical: true)
                        if tooHeavy {
                            Text("Может не хватить ресурсов этого Mac")
                                .font(AzaStyle.caption)
                                .foregroundStyle(AzaStyle.warning)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.dictation.canChangeEngine || dictationLanguage == "ce")

            // Удаление одной модели, не трогая остальные: выгружаем из
            // памяти только её и стираем только её папку в кэше.
            if isDownloaded {
                Button {
                    Task { modelDeleteError = await model.dictation.deleteModelFiles(item) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AzaStyle.faint)
                }
                .buttonStyle(.plain)
                // Во время диктовки unloadModel — no-op (guard state == .idle),
                // и удаление папки выдернуло бы файлы из-под WhisperKit.
                .disabled(!model.dictation.canDeleteModels)
                .help("Удалить скачанную модель «\(item.title)» (\(item.sizeLabel))")
                .accessibilityLabel("Удалить модель «\(item.title)»")
            }
        }
    }

    private func tag(_ text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }

    /// Раскладка и чеченские опечатки включаются независимо.
    private var correctionCard: some View {
        Group {
            card("Автоматическое исправление") {
                settingToggle("Исправлять раскладку", isOn: $layoutCorrection,
                              help: "Например, ghbdtn → привет. Двойной правый Shift отменяет последнее исправление.")
                divider
                settingToggle("Опечатки в чеченском", isOn: $typoCorrection,
                              help: "Исправлять опечатки, если в словаре есть ровно один похожий вариант. Работает независимо от исправления раскладки.")
            }
            card("Правила исправления раскладки") {
                settingToggle("Пропускать неоднозначные слова", isOn: $ambiguityAbstention,
                              help: "Не менять слово, если оно может быть и русским, и чеченским.")
                divider
                settingToggle("Исправлять в латиницу", isOn: $latinization,
                              help: "Обратное направление: ыфдфв → salad. Отключите, если это мешает набору кириллицей.")
            }
            .disabled(!layoutCorrection)
            card("Исключения") {
                // Строка видна всегда, даже при пустом списке — иначе
                // непонятно, куда деваются отменённые исправления.
                let exceptions = UserWordLists.shared.neverCorrect
                HStack {
                    // Перед «Очистить» список можно посмотреть: клик
                    // по счётчику раскрывает слова в поповере.
                    Button {
                        showExceptionWords = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("Слова-исключения: \(exceptions.count)")
                                .font(AzaStyle.body)
                                .foregroundStyle(exceptions.isEmpty ? AzaStyle.faint : AzaStyle.ink)
                            if !exceptions.isEmpty {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(AzaStyle.faint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(exceptions.isEmpty)
                    .popover(isPresented: $showExceptionWords, arrowEdge: .bottom) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(exceptions.sorted(), id: \.self) { word in
                                    Text(word)
                                        .font(AzaStyle.body)
                                        .foregroundStyle(AzaStyle.ink)
                                }
                            }
                            .padding(12)
                        }
                        .frame(minWidth: 160, maxHeight: 240)
                    }
                    HelpDot(text: "Слова, которые Aza больше не исправляет. Попадают сюда, когда вы отменяете исправление двойным правым Shift; клик по счётчику показывает список.")
                    Spacer(minLength: 8)
                    if !exceptions.isEmpty {
                        Button("Очистить") {
                            UserWordLists.shared.clearNeverCorrect()
                            showExceptionWords = false
                        }
                        .buttonStyle(AzaCapsuleButtonStyle())
                    }
                }
                .help("Двойной правый Shift отменяет исправление и заносит слово сюда")
                hint("Двойной правый Shift отменяет исправление и добавляет слово в исключения.")
                divider
                settingRow("Приложения-исключения", detail: "Общий список для автозамены и истории буфера.") {
                    Button("Настроить…") { showAppsSheet = true }
                        .buttonStyle(AzaCapsuleButtonStyle())
                }
            }
        }
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>,
                               help: String) -> some View {
        Toggle(isOn: isOn) { settingLabel(title, detail: help) }
            .toggleStyle(AzaToggleStyle())
            .accessibilityLabel(title)
            .accessibilityHint(help)
    }

    private func settingLabel(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(AzaStyle.body).foregroundStyle(AzaStyle.ink)
            if let detail { hint(detail) }
        }
    }

    private func settingRow<Control: View>(_ title: String, detail: String? = nil,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            settingLabel(title, detail: detail)
            Spacer(minLength: 0)
            control().fixedSize(horizontal: true, vertical: false)
        }
    }

    private var clipboardCard: some View {
        Group {
            card("История") {
                settingToggle("Сохранять историю буфера", isOn: $clipboardHistoryEnabled,
                              help: "Запоминает скопированное на этом Mac. При выключении новые записи не добавляются.")
                divider
                HotKeyRecorder(title: "Открыть историю", binding: $clipboardHotKey,
                               registrationError: model.clipboardHotKeyError) { binding in
                    binding.save(HotKeyBinding.clipboardKey,
                                 registering: model.rebindClipboardHotKey)
                }
                divider
                settingRow("Срок хранения", detail: "Старые записи удаляются автоматически. Избранное хранится без ограничения срока.") {
                    Picker("Срок хранения истории", selection: $retentionDays) {
                        Text("7 дней").tag(7)
                        Text("30 дней").tag(30)
                        Text("180 дней").tag(180)
                    }
                    .labelsHidden()
                    .frame(width: 118)
                }
            }
            card("При копировании") {
                settingToggle("Показывать «Скопировано»", isOn: $copyFlash,
                              help: "Короткое подтверждение в острове, когда запись добавлена в историю.")
                divider
                settingRow("Звук", detail: "Проигрывается при добавлении новой записи.") {
                    Picker("Звук копирования", selection: $copySound) {
                        Text("Без звука").tag("")
                        Text("Тик").tag("tick")
                        Text("Бум").tag("pop")
                        Text("Динь").tag("ding")
                        Text("Маримба").tag("marimba")
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .onChange(of: copySound) { _, sound in IslandStore.playCopySound(sound) }
                }
            }
            card("Очистка") {
                settingRow("Очистить историю", detail: "Удалятся все записи, кроме избранного.") {
                    Button("Очистить…", role: .destructive) { confirmHistoryClear = true }
                        .buttonStyle(AzaCapsuleButtonStyle())
                }
            }
        }
        .alert("Очистить историю буфера?", isPresented: $confirmHistoryClear) {
            Button("Отмена", role: .cancel) {}
            Button("Очистить историю", role: .destructive) { model.clearClipboardHistory() }
        } message: {
            Text("Все записи, кроме избранного, будут удалены. Это действие нельзя отменить.")
        }
    }

    private var phrasesCard: some View {
        Group {
            card("Быстрая вставка") {
                HotKeyRecorder(title: "Открыть фразы", binding: $phrasesHotKey,
                               registrationError: model.phrasesHotKeyError) { binding in
                    binding.save(HotKeyBinding.phrasesKey,
                                 registering: model.rebindPhrasesHotKey)
                }
                hint("Удерживайте правую ⌥ или сочетание выше и нажмите цифру 1–0. С зажатым ⇧ вставляется вариант фразы, без ⇧ — основная фраза. Если ⇧ входит в сочетание открытия, отпустите его для основной фразы. Можно выбрать фразу кликом.")
            }
            card("Ваши фразы") {
                HStack(spacing: 8) {
                    Text("№").frame(width: 20)
                    Text("Основная фраза").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Вариант с ⇧").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.muted)
                ForEach(0..<PhraseStore.slotCount, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text("\((index + 1) % 10)")
                            .font(AzaStyle.caption.monospacedDigit())
                            .foregroundStyle(AzaStyle.muted)
                            .frame(width: 20)
                        TextField("Фраза \(index + 1)", text: phraseField(index, alternate: false))
                            .accessibilityLabel("Фраза \(index + 1)")
                        TextField("Необязательно", text: phraseField(index, alternate: true))
                            .accessibilityLabel("Вариант фразы \(index + 1) с Shift")
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(AzaStyle.body)
                }
                divider
                if let error = phraseStore.saveError {
                    Text(error).foregroundStyle(.red).font(AzaStyle.caption)
                    Button("Повторить сохранение") { phraseStore.save() }
                        .buttonStyle(AzaCapsuleButtonStyle())
                }
                settingRow("Исходные фразы", detail: "Восстановить стандартный набор Aza.") {
                    Button("Восстановить…") { confirmPhraseReset = true }
                        .buttonStyle(AzaCapsuleButtonStyle())
                        .disabled(!phraseStore.isCustomized && phraseStore.saveError == nil)
                }
            }
        }
        .alert("Восстановить исходные фразы?", isPresented: $confirmPhraseReset) {
            Button("Отмена", role: .cancel) {}
            Button("Восстановить", role: .destructive) { phraseStore.resetToFactory() }
        } message: {
            Text("Ваши изменения во всех десяти фразах будут потеряны. Это действие нельзя отменить.")
        }
    }

    /// Половина слота фразы как отдельное поле; «|» живёт только в
    /// хранилище, поэтому из набранного текста он вырезается.
    private func phraseField(_ index: Int, alternate: Bool) -> Binding<String> {
        Binding(
            get: {
                let parts = PhraseStore.parts(phraseStore.phrases[index])
                return alternate ? parts.alt : parts.main
            },
            set: { newValue in
                let clean = newValue.replacingOccurrences(of: "|", with: "")
                var parts = PhraseStore.parts(phraseStore.phrases[index])
                if alternate { parts.alt = clean } else { parts.main = clean }
                phraseStore.update(index, text: PhraseStore.join(
                    main: parts.main, alt: parts.alt))
            }
        )
    }

    private var generalCard: some View {
        Group {
            card("Знакомство с Aza") {
                settingRow("Возможности и примеры", detail: "Диктовка, автозамена, буфер, фразы и намаз — попробуйте каждый шаг.") {
                    Button(model.onboarding.completed ? "Посмотреть" : "Продолжить") {
                        if model.onboarding.step == .finish { model.onboarding.go(to: .welcome) }
                        model.showsOnboarding = true
                    }
                    .buttonStyle(AzaCapsuleButtonStyle())
                }
            }
            card("Запуск") {
                settingToggle("Запускать вместе с macOS", isOn: Binding(
                    get: { model.loginItem == .enabled },
                    set: { model.setLoginItem($0) }
                ), help: "Aza будет готова к работе сразу после входа в систему.")
                if let error = model.loginItemError { warn("Не удалось: \(error)") }
                if model.loginItem == .requiresApproval {
                    hint("Подтвердите в Системных настройках → Элементы входа.")
                }
            }
            card("На экране") {
                settingToggle("Aza в строке меню", isOn: $menuBarIconVisible,
                              help: "Быстрый доступ к действиям и настройкам. Настройки также доступны из острова.")
                divider
                settingRow("Содержимое строки меню", detail: "Время ближайшего намаза обновляется автоматически для выбранного города.") {
                    Picker("Содержимое строки меню", selection: $menuBarDisplay) {
                        ForEach(MenuBarDisplay.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 155)
                    .disabled(!menuBarIconVisible)
                }
                divider
                settingRow("Показывать остров", detail: "Компактная панель у выреза экрана. История и диктовка доступны при любом режиме.") {
                    Picker("Показывать остров", selection: $islandMode) {
                        Text("По событиям").tag("auto")
                        Text("Всегда").tag("pinned")
                        Text("Скрывать").tag("hidden")
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
        }
    }

    // MARK: Составные части

    enum Status { case granted, missing, unknown }

    private func status(_ value: AVAuthorizationStatus) -> Status {
        switch value {
        case .authorized: .granted
        case .notDetermined: .unknown
        default: .missing
        }
    }

    private func status(_ value: UNAuthorizationStatus) -> Status {
        switch value {
        case .authorized, .provisional: .granted
        case .notDetermined: .unknown
        default: .missing
        }
    }

    private var divider: some View {
        Rectangle().fill(AzaStyle.line.opacity(0.6)).frame(height: 1)
    }

    /// Назначение разрешения видно всегда, действие — только если доступ не выдан.
    @ViewBuilder
    private func permissionRow<Actions: View>(
        _ title: String,
        symbol: String,
        status: Status,
        detail: String,
        denied: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AzaStyle.muted)
                    .frame(width: 20, height: 20)
                    .background(AzaStyle.control,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title).font(AzaStyle.label).foregroundStyle(AzaStyle.ink)
                Spacer()
                statusBadge(status)
            }
            hint(detail)
            if status != .granted {
                // Отклонённое разрешение система повторно не спрашивает —
                // вместо бесполезной кнопки говорим, где его включить.
                if status == .missing, let denied {
                    hint(denied)
                } else {
                    actions()
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: Status) -> some View {
        switch status {
        case .granted:
            Label("Выдано", systemImage: "checkmark")
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.muted)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(AzaStyle.control, in: Capsule())
        case .missing:
            Text("Не выдано")
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.faint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(AzaStyle.control, in: Capsule())
        case .unknown:
            Text("Не запрошено").font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
        }
    }

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AzaStyle.muted)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AzaStyle.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AzaStyle.line.opacity(0.65)))
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(AzaStyle.caption)
            .foregroundStyle(AzaStyle.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warn(_ text: String) -> some View {
        Text(text)
            .font(AzaStyle.caption)
            .foregroundStyle(AzaStyle.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Что хранится на диске и как это удалить (§20). Раньше жило в меню
/// строки меню, где занимало половину списка и дублировало настройки.
private struct DataSheet: View {
    @ObservedObject var model: SetupModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PrivacyCleanup.Item] = []
    @State private var error: String?
    @State private var confirmWipe = false
    /// У каждого удаления — отдельное подтверждение с описанием последствий.
    @State private var confirmModels = false
    @State private var confirmHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Данные на этом Mac")
                .font(AzaStyle.sectionTitle)
                .foregroundStyle(AzaStyle.ink)
            VStack(spacing: 12) {
                ForEach(items) { item in
                    HStack {
                        Text(item.title).font(AzaStyle.body)
                        Spacer(minLength: 8)
                        Text(PrivacyCleanup.humanSize(item.bytes))
                            .font(AzaStyle.caption.monospacedDigit())
                            .foregroundStyle(AzaStyle.muted)
                    }
                }
            }
            .padding(16)
            .background(AzaStyle.card, in: RoundedRectangle(cornerRadius: 10))

            Text(PrivacyCleanup.outboundTraffic)
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text("Не удалось удалить — \(error)")
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(AzaStyle.line)
            let busy = !model.dictation.canDeleteModels
            HStack {
                Text("Модели диктовки").font(AzaStyle.body)
                Spacer()
                Button("Удалить модели…") { confirmModels = true }
                    .buttonStyle(AzaCapsuleButtonStyle())
                    .disabled(busy)
            }
            HStack {
                Text("Вся история, включая избранное").font(AzaStyle.body)
                Spacer()
                Button("Удалить…") { confirmHistory = true }
                    .buttonStyle(AzaCapsuleButtonStyle())
            }
            HStack {
                Text("Все данные и настройки Aza").font(AzaStyle.body)
                Spacer()
                Button("Удалить всё…") { confirmWipe = true }
                    .buttonStyle(AzaCapsuleButtonStyle(foreground: AzaStyle.danger))
                    .disabled(busy)
            }
            if busy {
                Text("Удаление моделей доступно после завершения диктовки.")
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.faint)
            }
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                    .buttonStyle(AzaCapsuleButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .foregroundStyle(AzaStyle.ink)
        .background(AzaStyle.stage)
        .preferredColorScheme(.dark)
        .task { refresh() }
        .alert("Удалить модели диктовки?", isPresented: $confirmModels) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить модели", role: .destructive) {
                Task {
                    error = await model.dictation.deleteModels()
                    refresh()
                }
            }
        } message: {
            Text("Для следующей диктовки потребуется снова скачать модель.")
        }
        .alert("Удалить всю историю буфера?", isPresented: $confirmHistory) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить историю", role: .destructive) {
                error = PrivacyCleanup.deleteClipboardHistory()
                refresh()
            }
        } message: {
            Text("Будут удалены все записи, включая избранное. Это действие нельзя отменить.")
        }
        .alert("Удалить все данные Aza?", isPresented: $confirmWipe) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить всё", role: .destructive) {
                Task { error = await model.dictation.deleteAllData(prayer: model.prayer) }
            }
        } message: {
            Text("История, модели, слова, расписания и настройки будут удалены. Aza закроется. Это действие нельзя отменить.")
        }
    }

    private func refresh() {
        Task { items = await PrivacyCleanup.inventorySnapshot() }
    }
}

/// Приложения, в которых Aza молчит: ни исправлений, ни истории (§8.9).
private struct AppExclusionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var apps = UserDefaults.standard
        .stringArray(forKey: ExcludedApps.userDefaultsKey) ?? []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Приложения-исключения")
                .font(AzaStyle.sectionTitle)
                .foregroundStyle(AzaStyle.ink)
            Text("Aza не исправляет текст и не записывает историю, пока активно одно из этих приложений.")
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.faint)
                .fixedSize(horizontal: false, vertical: true)

            if apps.isEmpty {
                Label("Вы пока не добавили исключения", systemImage: "app.dashed")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.muted)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(apps, id: \.self) { bundleID in
                            HStack(spacing: 8) {
                                Image(nsImage: Self.icon(for: bundleID))
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                Text(Self.displayName(for: bundleID))
                                    .font(AzaStyle.body)
                                    .foregroundStyle(AzaStyle.ink)
                                    .lineLimit(1)
                                    .help(bundleID)
                                Spacer(minLength: 8)
                                Button {
                                    apps.removeAll { $0 == bundleID }
                                    save()
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(AzaStyle.muted)
                                .accessibilityLabel("Убрать исключение: \(Self.displayName(for: bundleID))")
                            }
                        }

                    }
                    .padding(12)
                }
                .frame(height: min(CGFloat(apps.count) * 34 + 24, 240))
                .background(AzaStyle.card, in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                // Запущенные приложения — один клик, без bundle ID.
                Menu("Из запущенных") {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Button {
                            add(app.bundleID)
                        } label: {
                            Text(app.name)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Выбрать из Программ…") { pickFromFinder() }
                    .buttonStyle(AzaCapsuleButtonStyle())
            }

            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(AzaStyle.stage)
        .preferredColorScheme(.dark)
    }

    /// Обычные запущенные приложения (не фоновые агенты), кроме самой
    /// Aza и уже добавленных.
    private var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier,
                      !apps.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func pickFromFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }

    private func add(_ bundleID: String) {
        guard !apps.contains(bundleID) else { return }
        apps.append(bundleID)
        save()
    }

    static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func save() {
        UserDefaults.standard.set(apps, forKey: ExcludedApps.userDefaultsKey)
    }
}

/// Значок «?» рядом с пунктом настроек: пояснение открывается кликом.
/// Тексты раньше жили в .help() — подсказку по наведению почти никто
/// не обнаруживает.
struct HelpDot: View {
    let text: String
    @State private var isOpen = false

    var body: some View {
        Button { isOpen = true } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(AzaStyle.faint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Подробнее")
        .accessibilityHint(text)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            Text(text)
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(width: 230, alignment: .leading)
        }
    }
}

/// Режим уведомления по каждому намазу и интервал напоминания.
/// Хранение и планирование уже жили в PrayerNotifications — здесь только
/// интерфейс к ним.
private struct PrayerNotificationsSheet: View {
    let prayer: PrayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var modes: [PrayerKind: PrayerNotifications.Mode]
    @AppStorage(PrayerNotifications.reminderMinutesKey) private var reminderMinutes = 10

    init(prayer: PrayerStore) {
        self.prayer = prayer
        _modes = State(initialValue: Dictionary(
            uniqueKeysWithValues: PrayerKind.allCases.map {
                ($0, PrayerNotifications.mode(for: $0))
            }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Уведомления о намазах")
                .font(AzaStyle.sectionTitle)
                .foregroundStyle(AzaStyle.ink)

            Text("Выберите режим для каждого намаза. Изменения применяются сразу.")
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.muted)
            ForEach(PrayerKind.allCases, id: \.self) { kind in
                HStack(spacing: 8) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(AzaStyle.muted)
                        .frame(width: 16)
                    Text(kind.title)
                        .font(AzaStyle.body)
                        .foregroundStyle(AzaStyle.ink)
                    Spacer(minLength: 8)
                    Picker("Уведомление: \(kind.title)", selection: binding(for: kind)) {
                        ForEach(PrayerNotifications.Mode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }

            if modes.values.contains(.reminder) {
                Divider().overlay(AzaStyle.line)
                HStack {
                    Text("Напоминать за")
                        .font(AzaStyle.body)
                        .foregroundStyle(AzaStyle.ink)
                    Spacer(minLength: 8)
                    Picker("За сколько минут напоминать", selection: $reminderMinutes) {
                        ForEach([5, 10, 15, 20, 30], id: \.self) { minutes in
                            Text("\(minutes) мин").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .onChange(of: reminderMinutes) {
                        prayer.rescheduleNotifications()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(AzaStyle.stage)
        .preferredColorScheme(.dark)
        .tint(AzaStyle.rise)
    }

    private func binding(for kind: PrayerKind) -> Binding<PrayerNotifications.Mode> {
        Binding(
            get: { modes[kind] ?? .notification },
            set: { mode in
                modes[kind] = mode
                UserDefaults.standard.set(mode.rawValue,
                                          forKey: PrayerNotifications.modeKey(for: kind))
                prayer.rescheduleNotifications()
            }
        )
    }
}
