import AVFoundation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Настройка и состояние разрешений (§9) в дизайн-системе Aza.
///
/// Компактная группировка: разрешения — строками в одной карточке, а не
/// семь крупных блоков; объяснение показывается там, где от пользователя
/// ещё требуется действие, а выданное разрешение сворачивается в строку
/// со статусом.
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
    @StateObject private var locator = CityLocator()
    @State private var showPermissions = false
    @AppStorage(ChechenAutocorrect.layoutStorageKey) private var layoutCorrection = true
    @AppStorage(ChechenAutocorrect.typoStorageKey) private var typoCorrection = false
    @AppStorage(ChechenAutocorrect.ambiguityStorageKey) private var ambiguityAbstention = true
    @AppStorage(ChechenAutocorrect.latinizationStorageKey) private var latinization = true
    @AppStorage(ClipboardStore.retentionKey) private var retentionDays = 30
    @AppStorage(IslandStore.copyFlashKey) private var copyFlash = true
    @AppStorage(IslandStore.copySoundKey) private var copySound = ""
    @AppStorage(IslandStore.compactModeKey) private var islandMode = "auto"
    @AppStorage(AzaApp.menuBarIconKey) private var menuBarIconVisible = true
    @State private var dictationHotKey = HotKeyBinding.load(
        HotKeyBinding.dictationKey, fallback: .dictationDefault)
    @State private var clipboardHotKey = HotKeyBinding.load(
        HotKeyBinding.clipboardKey, fallback: .clipboardDefault)
    @State private var phrasesHotKey = HotKeyBinding.load(
        HotKeyBinding.phrasesKey, fallback: .phrasesDefault)
    @ObservedObject private var phraseStore = PhraseStore.shared
    /// Сброс фраз требует второго нажатия: молчаливая потеря правок —
    /// ловушка.
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
    /// Разделы, переехавшие из меню: там они дублировали настройки и
    /// растягивали список на два экрана. Здесь — за кнопкой, чтобы окно
    /// по-прежнему помещалось целиком.
    @State private var showDataSheet = false
    @State private var showAppsSheet = false
    @State private var showExceptionWords = false
    @State private var showPrayerNotifSheet = false
    /// Характеристики этого Mac — под них подбирается рекомендация.
    private let capabilities = MacCapabilities.current()

    /// Разделы окна: сайдбар слева, содержимое справа — вместо ленты из
    /// шести карточек на одном экране.
    ///
    /// Раздел = фича, а не тип контрола: хоткей диктовки лежит в
    /// «Диктовке», настройки буфера — в «Буфере обмена». Отдельная вкладка
    /// «Горячие клавиши» из двух строк заставляла искать настройку одной
    /// фичи в двух местах. «Общее» — только про само приложение.
    private enum Section: String, CaseIterable {
        case prayer, dictation, correction, clipboard, phrases, general, permissions

        var title: String {
            switch self {
            case .prayer: "Намаз"
            case .dictation: "Диктовка"
            case .correction: "Автозамена"
            case .clipboard: "Буфер обмена"
            case .phrases: "Фразы"
            case .general: "Общее"
            case .permissions: "Разрешения"
            }
        }

        var symbol: String {
            switch self {
            case .prayer: "moon.stars.fill"
            case .dictation: "mic"
            case .correction: "keyboard"
            case .clipboard: "doc.on.clipboard"
            case .phrases: "text.bubble"
            case .general: "gearshape"
            case .permissions: "checkmark.shield"
            }
        }
    }

    @State private var section: Section = .prayer

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        // Высота — по самому длинному разделу («Диктовка»): настройки
        // должны помещаться целиком, скролл остаётся только страховкой
        // для маленьких экранов.
        .frame(width: 680, height: 620)
        .background(AzaStyle.stage)
        .preferredColorScheme(.dark)
        // Закрыли настройки — прослушивание смолкло. Звук, доигрывающий
        // за закрытым окном, пользователь остановить уже не может.
        .onDisappear { soundPreview.stop() }
        // Клик по городу в острове ведёт именно к выбору города, а не к
        // разделу, оставшемуся открытым с прошлого раза.
        .onReceive(NotificationCenter.default.publisher(for: .azaShowPrayerSettings)) { _ in
            section = .prayer
        }
        .onReceive(NotificationCenter.default.publisher(for: .azaShowPhraseSettings)) { _ in
            section = .phrases
        }
        .sheet(isPresented: $showDataSheet) { DataSheet(model: model) }
        .sheet(isPresented: $showAppsSheet) { AppExclusionsSheet() }
        .sheet(isPresented: $showPrayerNotifSheet) {
            PrayerNotificationsSheet(prayer: model.prayer)
        }
    }

    // MARK: Сайдбар и содержимое

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AzaStyle.acid)
                    .frame(width: 28, height: 28)
                    .background(AzaStyle.acidSurface, in: RoundedRectangle(
                        cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aza").font(AzaStyle.sectionTitle).foregroundStyle(AzaStyle.ink)
                    Text("Всё локально")
                        .font(AzaStyle.caption)
                        .foregroundStyle(AzaStyle.faint)
                }
            }
            .padding(.bottom, 14)

            ForEach(Section.allCases, id: \.self) { item in
                sidebarRow(item)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 200, alignment: .topLeading)
        .background(AzaStyle.deep)
        .overlay(alignment: .trailing) {
            AzaStyle.line.frame(width: 1)
        }
    }

    private func sidebarRow(_ item: Section) -> some View {
        Button {
            section = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(section == item ? Color.black : AzaStyle.muted)
                Text(item.title)
                    .font(AzaStyle.body)
                    .foregroundStyle(section == item ? Color.black : AzaStyle.ink)
                Spacer(minLength: 0)
                // Невыданные права видны прямо из сайдбара.
                if item == .permissions, !missingPermissions.isEmpty {
                    Circle().fill(section == item ? Color.black : AzaStyle.warning)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(section == item ? AzaStyle.acid : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.title)
                        .font(AzaStyle.title)
                        .foregroundStyle(AzaStyle.ink)
                        .padding(.bottom, 2)
                    switch section {
                    case .prayer: prayerCard
                    case .dictation: dictationCard
                    case .correction: correctionCard
                    case .clipboard: clipboardCard
                    case .phrases: phrasesCard
                    case .general: generalCard
                    case .permissions: permissionsCard
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Главное действие окна — в правом нижнем углу, как принято
            // на macOS, а не в сайдбаре.
            HStack {
                Spacer()
                Button("Готово") {
                    UserDefaults.standard.set(true, forKey: SetupWindowController.completedKey)
                    // performClose, а не close: закрытие идёт через делегата
                    // окна — с анимацией ухода вверх. Окно ищем по делегату,
                    // а не через keyWindow: приложение может быть неактивным
                    // (кооперативная активация на этой macOS не проходит),
                    // и keyWindow == nil молча съедал закрытие.
                    NSApp.windows
                        .first { $0.delegate is SetupWindowController }?
                        .performClose(nil)
                }
                .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .background(AzaStyle.stage)
    }

    // MARK: Разрешения — одной группой

    /// Выданные разрешения не занимают экран: пока всё в порядке, это
    /// одна строка с кнопкой. Невыданные показываются сразу — их видеть
    /// нужно, иначе функция молча не работает.
    private var permissionsCard: some View {
        card("Разрешения") {
            let missing = missingPermissions
            HStack(spacing: 8) {
                Image(systemName: missing.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(missing.isEmpty ? AzaStyle.acid : AzaStyle.warning)
                Text(missing.isEmpty
                     ? "Все выданы"
                     : "Не выдано: \(missing.joined(separator: ", "))")
                    .font(AzaStyle.label)
                    .foregroundStyle(missing.isEmpty ? AzaStyle.ink : AzaStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(showPermissions ? "Скрыть" : "Показать") {
                    withAnimation(.easeOut(duration: AzaMotion.micro)) {
                        showPermissions.toggle()
                    }
                }
                .buttonStyle(AzaCapsuleButtonStyle())
            }
            if showPermissions || !missing.isEmpty {
                divider
                permissionRows
            }
        }
    }

    /// Названия невыданных разрешений — для сводки.
    private var missingPermissions: [String] {
        var result: [String] = []
        // Незапрошенное разрешение (.unknown) тоже не выдано: иначе
        // сводка сказала бы «все выданы», спрятав нужную кнопку.
        if status(model.notifications) != .granted { result.append("уведомления") }
        if status(model.microphone) != .granted { result.append("микрофон") }
        if !model.axTrusted { result.append("управление компьютером") }
        if !model.inputMonitoring { result.append("мониторинг ввода") }
        return result
    }

    @ViewBuilder
    private var permissionRows: some View {
        Group {
            permissionRow(
                "Уведомления", symbol: "bell",
                visible: showPermissions || status(model.notifications) != .granted,
                status: status(model.notifications),
                detail: "Напоминание ко времени намаза.",
                denied: "Включается в Системных настройках → Уведомления"
            ) {
                Button("Разрешить") { Task { await model.requestNotifications() } }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
            }

            permissionRow(
                "Микрофон", symbol: "mic",
                visible: showPermissions || status(model.microphone) != .granted,
                status: status(model.microphone),
                detail: "Нужен для диктовки; аудио не сохраняется на диск.",
                denied: "Включается в Системных настройках → Микрофон"
            ) {
                Button("Разрешить") { model.requestMicrophone() }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
            }

            permissionRow(
                "Управление компьютером", symbol: "hand.tap",
                visible: showPermissions || !model.axTrusted,
                status: model.axTrusted ? .granted : .missing,
                detail: "Вставка текста прямо в поле. Без него текст остаётся в буфере."
            ) {
                Button("Открыть настройки") { model.requestAccessibility() }
                    .buttonStyle(AzaCapsuleButtonStyle())
            }

            permissionRow(
                "Мониторинг ввода", symbol: "keyboard",
                visible: showPermissions || !model.inputMonitoring,
                status: model.inputMonitoring ? .granted : .missing,
                detail: "Нужен для исправления раскладки. Действует после перезапуска Aza."
            ) {
                HStack(spacing: 6) {
                    Button("Разрешить") { model.requestInputMonitoring() }
                        .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
                    Button("Перезапустить") { model.restartApp() }
                        .buttonStyle(AzaCapsuleButtonStyle())
                }
            }
        }
    }

    // MARK: Остальные разделы

    private var prayerCard: some View {
        card("Намаз") {
            HStack(spacing: 8) {
                CityPickerView(cityID: $cityID, cities: model.prayer.allCities)
                    .buttonStyle(AzaCapsuleButtonStyle())
                    .onChange(of: cityID) { _, value in
                        model.prayer.selectedCityID = value.isEmpty ? nil : value
                    }
                Button(locator.state == .locating ? "Определяю…" : "По геопозиции") {
                    Task {
                        if let match = await locator.locate() {
                            cityID = match.city.id
                            model.prayer.selectedCityID = match.city.id
                        }
                    }
                }
                .buttonStyle(AzaCapsuleButtonStyle())
                .disabled(locator.state == .locating)
                HelpDot(text: "Город, по которому берутся времена намаза. «По геопозиции» подбирает ближайший профиль из списка.")
            }
            switch locator.state {
            case let .found(id, distance):
                // Честно: ближайший ПРОФИЛЬ из списка, а не «ваш город».
                hint("Ближайший профиль: \(model.prayer.allCities.first { $0.id == id }?.name ?? id) · \(distance) км")
            case .denied:
                warn("Геолокация запрещена — выберите город вручную")
            case let .failed(message):
                warn(message)
            default:
                EmptyView()
            }
            if !cityID.isEmpty {
                divider
                sourceStatus
                divider
                soundPicker
                divider
                HStack(spacing: 6) {
                    Text("Уведомления")
                        .font(AzaStyle.body)
                        .foregroundStyle(AzaStyle.ink)
                    HelpDot(text: "Главный тумблер уведомлений о намазе; включение спрашивает разрешение системы. Режим по каждому намазу — за кнопкой «Настроить…».")
                    Spacer(minLength: 8)
                    // Единственный путь, включающий уведомления (пишет
                    // PrayerNotificationsEnabled и планирует расписание).
                    // Раньше тумблера не было, и функция была невключаемой.
                    Toggle(isOn: Binding(
                        get: { model.prayer.notificationsEnabled },
                        set: { on in Task { await model.prayer.setNotifications(enabled: on) } }
                    )) { EmptyView() }
                        .toggleStyle(AzaToggleStyle())
                    Button("Настроить…") { showPrayerNotifSheet = true }
                        .buttonStyle(AzaCapsuleButtonStyle())
                        .disabled(!model.prayer.notificationsEnabled)
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
                Picker("", selection: $prayerSound) {
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
                .foregroundStyle(soundPreview.playing != nil ? AzaStyle.acid : AzaStyle.muted)
                .background(AzaStyle.control, in: Circle())
                .overlay(Circle().stroke(AzaStyle.line))
                .help(soundPreview.playing != nil ? "Остановить" : "Прослушать")
                // У системного звука файла нет — играть нечего.
                .disabled(PrayerNotifications.Sound(rawValue: prayerSound)?.fileName == nil)
            }
            if PrayerNotifications.Sound(rawValue: prayerSound)?.isAdhan == true {
                hint("Азан звучит целиком: запись укладывается в системный "
                     + "предел уведомления в 30 секунд.")
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
                                           : (table ? AzaStyle.acid : AzaStyle.muted))
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

    // Порядок строк — путь пользователя: как включить (клавиша), что
    // распознаётся (язык, свои слова, модель), и в конце — чем звучит.
    private var dictationCard: some View {
        card("Диктовка") {
            HotKeyRecorder(title: "Клавиша", binding: $dictationHotKey, allowModifierKeys: true) { binding in
                binding.save(HotKeyBinding.dictationKey)
                model.dictation.rebindHotKey()
            }
            hint("Удерживайте для записи; двойное нажатие фиксирует — фиксацию остановят сочетание, Пробел или Enter.")
            divider
            HStack {
                Text("Язык")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "Язык распознавания диктовки. Авто определяет по речи; при сомнении выбирается русский.")
                Spacer(minLength: 8)
                Picker("", selection: $dictationLanguage) {
                    Text("Авто").tag("auto")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            divider
            HStack {
                Text("Свои слова")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "Имена и термины через запятую. Whisper получает их как подсказку и реже коверкает такие слова.")
                Spacer(minLength: 8)
                TextField("Ахьмад, Соьлжа-ГӀала", text: $dictationCustomWords)
                    .textFieldStyle(.roundedBorder)
                    .font(AzaStyle.body)
                    .frame(width: 200)
            }
            divider
            settingToggle("Убирать звуки-паразиты", isOn: $removeFillers,
                          help: "«Эм», «э-э», “uh” вырезаются из текста. Настоящие слова («ну», «вот») не трогаются никогда.")
            divider
            settingToggle("Распознавать во время записи", isOn: $streamingDictation,
                          help: "Текст распознаётся, пока вы говорите, — после отпускания остаётся дораспознать только хвост. Работает при явно выбранном языке (не «Авто»). Тратит чуть больше энергии во время записи.")
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
                Picker("", selection: Binding(
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
            divider
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
            if let progress = model.dictation.downloadProgress, progress < 0.999 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(AzaStyle.acid)
                    Text("Загрузка: \(Int(progress * 100))%")
                        .font(AzaStyle.caption)
                        .foregroundStyle(AzaStyle.faint)
                }
            } else if case .loadingModel = model.dictation.state {
                Text("Готовлю модель…")
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.faint)
            } else if let selected = DictationController.Profile(rawValue: profile),
                      !DictationController.isModelCached(selected) {
                Button("Скачать модель · \(selected.sizeLabel)") {
                    model.dictation.downloadSelectedModel()
                }
                .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
                // Скачивание обнуляет модель в памяти — во время диктовки
                // нельзя, как и удаление (guard дублируется в контроллере).
                .disabled(model.dictation.state != .idle)
            }
            divider
            HStack {
                Text("Звук сигналов")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "Пара звуков начала и конца диктовки: вверх — запись пошла, вниз — распознаю.")
                Spacer(minLength: 8)
                Picker("", selection: $toneSet) {
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
                    .controlSize(.small)
                    .tint(AzaStyle.acid)
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
                    .foregroundStyle(isSelected ? AzaStyle.acid : AzaStyle.faint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(AzaStyle.label)
                            .foregroundStyle(AzaStyle.ink)
                        if isRecommended {
                            tag("Рекомендуем", color: AzaStyle.acid,
                                background: AzaStyle.acidSurface)
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
                .disabled(model.dictation.state != .idle)
                .help("Удалить скачанную модель «\(item.title)» (\(item.sizeLabel))")
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

    /// Автозамена (§10 «Раскладка»): главный тумблер и отдельно —
    /// исправление опечаток, самая рискованная стадия.
    private var correctionCard: some View {
        card("Автозамена") {
            settingToggle("Раскладка", isOn: $layoutCorrection,
                          help: "ghbdtn → привет, [mj → хьо, 1алам → ӏалам")
            if layoutCorrection {
                settingToggle("Опечатки", isOn: $typoCorrection,
                              help: "Чеченские слова с опечаткой — только когда в словаре ровно один похожий вариант.")
                settingToggle("Пропускать спорные", isOn: $ambiguityAbstention,
                              help: "Если слово читается и как русское, и как чеченское — Aza промолчит.")
                settingToggle("Латинизация", isOn: $latinization,
                              help: "Обратное направление: ыфдфв → salad. Выключите, если Aza мешает при наборе кириллицей.")
                // Строка видна всегда, даже при пустом списке — иначе
                // непонятно, куда деваются отменённые исправления.
                let exceptions = UserWordLists.shared.neverCorrect
                divider
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
            }
        }
    }

    /// Компактная строка настройки: подпись, «?» с пояснением,
    /// переключатель. Пояснение — по клику, не только по наведению:
    /// подсказки при наведении никто не находит.
    private func settingToggle(_ title: String, isOn: Binding<Bool>,
                               help: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(AzaStyle.body)
                .foregroundStyle(AzaStyle.ink)
            HelpDot(text: help)
            Spacer(minLength: 8)
            Toggle(isOn: isOn) { EmptyView() }
                .toggleStyle(AzaToggleStyle())
        }
    }

    /// Буфер обмена: всё про историю копирований в одном месте — клавиша,
    /// срок хранения и обратная связь при копировании. Раньше это было
    /// размазано между «Общее» и «Горячие клавиши».
    private var clipboardCard: some View {
        card("Буфер обмена") {
            HotKeyRecorder(title: "Клавиша", binding: $clipboardHotKey) { binding in
                binding.save(HotKeyBinding.clipboardKey)
                model.rebindClipboardHotKey()
            }
            hint("Открывает и закрывает историю буфера в острове.")
            divider
            HStack {
                Text("Хранить историю")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "Сколько живёт история буфера обмена: записи старше срока удаляются. Избранные (со звёздочкой) остаются навсегда.")
                Spacer(minLength: 8)
                Picker("", selection: $retentionDays) {
                    Text("Неделю").tag(7)
                    Text("Месяц").tag(30)
                    Text("Полгода").tag(180)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            divider
            settingToggle("Показывать «Скопировано»", isOn: $copyFlash,
                          help: "Остров у выреза на пару секунд подтверждает, что запись попала в историю буфера.")
            HStack {
                Text("Звук копирования")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "Короткий системный звук при каждой новой записи в истории буфера.")
                Spacer(minLength: 8)
                Picker("", selection: $copySound) {
                    Text("Без звука").tag("")
                    Text("Тик").tag("tick")
                    Text("Бум").tag("pop")
                    Text("Динь").tag("ding")
                    Text("Маримба").tag("marimba")
                }
                .labelsHidden()
                .frame(width: 130)
                // Выбор сразу проигрывается — иначе звук не подобрать.
                .onChange(of: copySound) { _, sound in
                    IslandStore.playCopySound(sound)
                }
            }
            divider
            HStack {
                if confirmHistoryClear {
                    Text("Избранное останется")
                        .font(AzaStyle.caption)
                        .foregroundStyle(AzaStyle.warning)
                }
                Spacer(minLength: 8)
                // §8.7: очистка истории с подтверждением, как сброс фраз.
                Button(confirmHistoryClear ? "Точно очистить" : "Очистить историю") {
                    if confirmHistoryClear {
                        model.clearClipboardHistory()
                    }
                    confirmHistoryClear.toggle()
                }
                .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.warning,
                                                   prominent: confirmHistoryClear))
            }
        }
    }

    /// Фразы быстрой вставки: клавиша, десять слотов и сброс до заводских.
    private var phrasesCard: some View {
        card("Фразы") {
            HotKeyRecorder(title: "Клавиша", binding: $phrasesHotKey) { binding in
                binding.save(HotKeyBinding.phrasesKey)
                model.rebindPhrasesHotKey()
            }
            hint("Удерживайте правую ⌥ (или сочетание выше) — остров "
                 + "покажет фразы. Вставляет клик или цифра 1–0, нажатая "
                 + "не отпуская клавишу. Правое поле — необязательный "
                 + "вариант фразы (женская форма, полное приветствие): "
                 + "он вставляется той же цифрой с ⇧.")
            divider
            ForEach(0..<PhraseStore.slotCount, id: \.self) { index in
                HStack(spacing: 8) {
                    Text("\((index + 1) % 10)")
                        .font(AzaStyle.caption.monospacedDigit())
                        .foregroundStyle(AzaStyle.acid)
                        .frame(width: 16)
                    TextField("Фраза \(index + 1)",
                              text: phraseField(index, alternate: false))
                    TextField("⇧-вариант",
                              text: phraseField(index, alternate: true))
                }
                .textFieldStyle(.roundedBorder)
                .font(AzaStyle.body)
            }
            HStack {
                if confirmPhraseReset {
                    Text("Ваши правки будут потеряны")
                        .font(AzaStyle.caption)
                        .foregroundStyle(AzaStyle.warning)
                }
                Spacer(minLength: 8)
                Button(confirmPhraseReset ? "Точно сбросить" : "Сбросить до заводских") {
                    if confirmPhraseReset {
                        phraseStore.resetToFactory()
                    }
                    confirmPhraseReset.toggle()
                }
                .buttonStyle(AzaCapsuleButtonStyle())
                .disabled(!phraseStore.isCustomized)
            }
        }
        .onChange(of: phraseStore.isCustomized) { _, _ in
            confirmPhraseReset = false
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

    /// Общее — только про само приложение: запуск, иконка, остров,
    /// данные. Настройки конкретных фич живут в своих разделах.
    private var generalCard: some View {
        card("Общее") {
            HStack(spacing: 6) {
                Text("Запускать вместе с macOS")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "Aza стартует в фоне при входе в систему — намаз, автозамена и буфер работают без ручного запуска.")
                Spacer(minLength: 8)
                Toggle(isOn: Binding(
                    get: { model.loginItem == .enabled },
                    set: { model.setLoginItem($0) }
                )) { EmptyView() }
                .toggleStyle(AzaToggleStyle())
            }
            if let error = model.loginItemError {
                warn("Не удалось: \(error)")
            }
            if model.loginItem == .requiresApproval {
                hint("Подтвердите в Системных настройках → Элементы входа.")
            }
            divider
            settingToggle("Иконка в строке меню", isOn: $menuBarIconVisible,
                          help: "Уберите, если иконка не нужна: остров и горячие клавиши работают без неё, а настройки открываются из панели острова.")
            HStack {
                Text("Остров у выреза")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "«По событиям» — появляется на несколько секунд при копировании и перед намазом. «Всегда» — закреплён и не прячется. «Скрыт» — не показывается вовсе; панели буфера и диктовки работают как обычно.")
                Spacer(minLength: 8)
                Picker("", selection: $islandMode) {
                    Text("По событиям").tag("auto")
                    Text("Всегда").tag("pinned")
                    Text("Скрыт").tag("hidden")
                }
                .labelsHidden()
                .frame(width: 130)
            }
            divider
            // Тот же паттерн строки, что и у остальных настроек: подпись
            // слева, действие справа — а не безымянные кнопки в ряд.
            HStack(spacing: 6) {
                Text("Приложения-исключения")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "Приложения, в которых Aza не исправляет текст и не записывает историю буфера.")
                Spacer(minLength: 8)
                Button("Настроить…") { showAppsSheet = true }
                    .buttonStyle(AzaCapsuleButtonStyle())
            }
            divider
            HStack(spacing: 6) {
                Text("Данные на диске")
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                HelpDot(text: "Что Aza хранит на диске: история буфера, модели диктовки, слова, расписания. Там же — удаление всех данных.")
                Spacer(minLength: 8)
                Button("Показать…") { showDataSheet = true }
                    .buttonStyle(AzaCapsuleButtonStyle())
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
        Rectangle().fill(AzaStyle.line).frame(height: 1).padding(.vertical, 1)
    }

    /// Строка разрешения: выданное сворачивается в одну строку, остальные
    /// показывают объяснение и действие — место тратится там, где нужно.
    @ViewBuilder
    private func permissionRow<Actions: View>(
        _ title: String,
        symbol: String,
        visible: Bool,
        status: Status,
        detail: String,
        denied: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        // Свёрнутая группа показывает только то, что требует внимания.
        if visible {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status == .granted ? AzaStyle.acid : AzaStyle.muted)
                    .frame(width: 20, height: 20)
                    .background(status == .granted ? AzaStyle.acidSurface : AzaStyle.control,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title).font(AzaStyle.label).foregroundStyle(AzaStyle.ink)
                Spacer()
                statusBadge(status)
            }
            if status != .granted {
                Text(detail)
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.faint)
                    .fixedSize(horizontal: false, vertical: true)
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
    }

    @ViewBuilder
    private func statusBadge(_ status: Status) -> some View {
        switch status {
        case .granted:
            Text("Выдано")
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.acid)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(AzaStyle.acidSurface, in: Capsule())
        case .missing:
            Text("Не выдано")
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.faint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(AzaStyle.control, in: Capsule())
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Заголовок раздела теперь над панелью (сайдбарная структура) —
        // внутри карточки он бы дублировался.
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AzaStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AzaStyle.line))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Данные на этом компьютере")
                .font(AzaStyle.sectionTitle)
                .foregroundStyle(AzaStyle.ink)

            ForEach(items) { item in
                HStack {
                    Text(item.title)
                        .font(AzaStyle.body)
                        .foregroundStyle(AzaStyle.ink)
                    Spacer(minLength: 8)
                    Text(PrivacyCleanup.humanSize(item.bytes))
                        .font(AzaStyle.caption.monospacedDigit())
                        .foregroundStyle(AzaStyle.muted)
                }
            }

            Text(PrivacyCleanup.outboundTraffic)
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.faint)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text("Не удалось удалить — \(error)")
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(AzaStyle.line)

            // Удаление доступно только когда диктовка свободна: иначе она
            // допишет файлы уже после удаления.
            let busy = model.dictation.state != .idle
            HStack(spacing: 8) {
                Button("Удалить модели") {
                    Task {
                        model.dictation.unloadModel()
                        // Дождаться остановки ВСЕХ загрузчиков (включая
                        // поднятых уборкой отменённого): иначе докачка
                        // пересоздаст только что стёртые файлы.
                        await model.dictation.shutdownLoadersForDeletion()
                        error = PrivacyCleanup.deleteModels()
                        refresh()
                    }
                }
                .buttonStyle(AzaCapsuleButtonStyle())
                .disabled(busy)
                Button("Удалить историю буфера") {
                    Task {
                        // Намаз здесь не глушится: удаление буфера его не
                        // касается, а превентивный shutdown при СБОЕ удаления
                        // оставлял приложение без напоминаний до перезапуска.
                        error = PrivacyCleanup.deleteClipboardHistory()
                    }
                }
                .buttonStyle(AzaCapsuleButtonStyle())
                Spacer()
            }
            if confirmWipe {
                Text("Удалить историю, модели, слова, расписания и настройки? Aza закроется.")
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.warning)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Да, удалить всё") {
                        guard !busy else {
                            error = "диктовка занята — попробуйте снова"
                            confirmWipe = false
                            return
                        }
                        Task {
                            // Остановка загрузчиков — ПОСЛЕДНЯЯ, впритык к
                            // удалению: между сбросом её защитного флага и
                            // deleteEverything не должно быть ни одного
                            // await, где нажатие клавиши подняло бы новую
                            // загрузку под сносимую папку.
                            await model.prayer.shutdownForCleanup()
                            model.dictation.unloadModel()
                            await model.dictation.shutdownLoadersForDeletion()
                            error = PrivacyCleanup.deleteEverything()
                        }
                    }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.danger, prominent: true))
                    Button("Отмена") { confirmWipe = false }
                        .buttonStyle(AzaCapsuleButtonStyle())
                    Spacer()
                }
            } else {
                Button("Удалить все данные Aza") { confirmWipe = true }
                    .buttonStyle(AzaCapsuleButtonStyle())
                    .disabled(busy)
            }
            if busy {
                Text("Удаление доступно, когда диктовка не занята")
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.faint)
            }

            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(AzaStyle.stage)
        .preferredColorScheme(.dark)
        .task { refresh() }
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
                }
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
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
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
                    Picker("", selection: binding(for: kind)) {
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
                    Picker("", selection: $reminderMinutes) {
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
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 400)
        .background(AzaStyle.stage)
        .preferredColorScheme(.dark)
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
