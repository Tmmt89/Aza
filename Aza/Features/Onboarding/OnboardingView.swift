import AVFoundation
import ServiceManagement
import SwiftUI

/// Учебные примеры используют только состояние окна. Настройка функций
/// ведёт в существующие разделы и не сбрасывает место в знакомстве.
struct OnboardingView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var progress: OnboardingProgress
    var configure: (OnboardingProgress.Step) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PasteboardMonitor.storageKey) private var historyEnabled = true
    @AppStorage(ChechenAutocorrect.layoutStorageKey) private var correctionEnabled = false
    @AppStorage(ClipboardStore.retentionKey) private var retentionDays = 30
    @State private var phase = 0
    @State private var favorite = false
    @State private var query = ""
    @State private var phrase = "Спасибо! Посмотрю и вернусь с ответом."
    @State private var alternate = false
    @State private var insertedPhrase = ""

    private typealias Step = OnboardingProgress.Step
    private let clipboardExample = "Обсудить макет завтра в 10:00"

    var body: some View {
        HStack(spacing: 0) {
            navigation
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heading
                        if progress.step == .welcome {
                            welcome
                        } else if progress.step == .finish {
                            finish
                        } else {
                            example
                            instructions
                            preparation
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .id(progress.step)
                footer
            }
        }
        .background(AzaStyle.stage)
        .foregroundStyle(AzaStyle.ink)
        .onChange(of: progress.step) { _, _ in
            phase = 0
            query = ""
            favorite = false
            alternate = false
            insertedPhrase = ""
        }
        .onAppear { model.refresh() }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 38, height: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Aza").font(.system(size: 18, weight: .semibold))
                    Text("Быстрый старт").font(AzaStyle.caption)
                        .foregroundStyle(AzaStyle.muted)
                }
            }
            .padding(.horizontal, 8)
            VStack(spacing: 5) {
                ForEach(Step.allCases, id: \.self) { step in
                    Button { progress.go(to: step) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: step.symbol).frame(width: 18).accessibilityHidden(true)
                            Text(step.title)
                            Spacer(minLength: 0)
                            if progress.examples.contains(step) {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                    .accessibilityHidden(true)
                            }
                        }
                        .font(.system(size: 12, weight: progress.step == step ? .semibold : .regular))
                        .foregroundStyle(progress.step == step ? AzaStyle.ink : AzaStyle.muted)
                        .padding(.horizontal, 10).frame(height: 38)
                        .background(progress.step == step ? AzaStyle.control : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .leading) {
                            if progress.step == step {
                                Capsule().fill(AzaStyle.rise).frame(width: 3, height: 14)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(step.title + (progress.examples.contains(step) ? ", пример пройден" : ""))
                    .accessibilityIdentifier("onboarding.\(step.rawValue)")
                    .accessibilityAddTraits(progress.step == step ? .isSelected : [])
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 7) {
                Label("В вашем темпе", systemImage: "bookmark")
                    .font(AzaStyle.label)
                Text("Можно закрыть окно и продолжить с этого места.")
                    .font(AzaStyle.caption).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(AzaStyle.faint).padding(8)
        }
        .padding(.horizontal, 12).padding(.vertical, 28)
        .frame(width: 184)
        .background(AzaStyle.card)
        .overlay(alignment: .trailing) { AzaStyle.line.opacity(0.5).frame(width: 1) }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ШАГ \((Step.allCases.firstIndex(of: progress.step) ?? 0) + 1) ИЗ \(Step.allCases.count)")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(AzaStyle.faint)
            Text(headline).font(.system(size: 28, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 13))
                .foregroundStyle(AzaStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        switch progress.step {
        case .welcome: "Привычные дела.\nНа пару действий меньше."
        case .dictation: "Скажите — Aza запишет"
        case .correction: "Ошиблись раскладкой?\nПродолжайте мысль."
        case .clipboard: "Скопированное\nостаётся под рукой"
        case .phrases: "Частые ответы —\nодним сочетанием"
        case .prayer: "Расписание рядом.\nНапоминания вовремя."
        case .finish: "Теперь вы знакомы с Aza"
        }
    }

    private var subtitle: String {
        switch progress.step {
        case .welcome: "Пять возможностей для повседневных дел на Mac. Каждую можно попробовать и настроить отдельно."
        case .dictation: "Превращайте речь в текст в любом приложении. Распознавание работает прямо на вашем Mac."
        case .correction: "Aza замечает неверную раскладку после завершения слова. Последнее исправление можно отменить."
        case .clipboard: "Найдите то, что копировали раньше, и вставьте снова — даже если уже скопировали что-то другое."
        case .phrases: "Сохраните приветствия, ответы или реквизиты и вставляйте их без повторного набора."
        case .prayer: "Выберите свой город: Aza покажет ближайший намаз и сможет напомнить о нём."
        case .finish: "Используйте нужные возможности. К остальным можно вернуться в любой момент."
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "apple.logo")
                    Text("Finder").fontWeight(.medium)
                    Spacer()
                    Button { phase = phase == 0 ? 1 : 0 } label: {
                        Image("MenuBarMark").renderingMode(.template)
                            .resizable().scaledToFit().frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain).help("Показать учебное меню Aza")
                    .accessibilityLabel("Показать учебное меню Aza")
                }
                .font(.system(size: 10)).padding(.horizontal, 18).frame(height: 30)
                .background(AzaStyle.control)
                VStack(spacing: 18) {
                    Label(phase == 0 ? "Aza рядом" : "Диктовка · Буфер · Настройки",
                          systemImage: phase == 0 ? "sparkles" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 22).frame(height: 42)
                        .background(.black, in: UnevenRoundedRectangle(
                            bottomLeadingRadius: 18, bottomTrailingRadius: 18))
                    Text("Остров у верхней кромки экрана")
                        .font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                    Text("Нажмите значок Aza в строке меню выше")
                        .font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
                }
                .frame(maxWidth: .infinity).padding(.bottom, 26)
            }
            .background(AzaStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            ForEach(Step.features, id: \.self) { step in
                HStack(spacing: 12) {
                    Image(systemName: step.symbol).frame(width: 22).foregroundStyle(AzaStyle.rise)
                    Text(step.title).font(.system(size: 12, weight: .semibold)).frame(width: 104, alignment: .leading)
                    Text(featureBenefit(step)).font(.system(size: 12)).foregroundStyle(AzaStyle.muted)
                }
            }
            Text("Закрытие окна не выключает Aza. Остров и строка меню открывают её действия и настройки.")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureBenefit(_ step: Step) -> String {
        switch step {
        case .dictation: "Говорите вместо набора"
        case .correction: "Исправляйте раскладку и опечатки"
        case .clipboard: "Возвращайтесь к скопированному"
        case .phrases: "Вставляйте готовые ответы"
        case .prayer: "Следите за расписанием своего города"
        default: ""
        }
    }

    private var example: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Попробуйте здесь", systemImage: "cursorarrow.rays")
                    .font(AzaStyle.label)
                Spacer()
                Text("УЧЕБНЫЙ ПРИМЕР").font(.system(size: 9, weight: .semibold))
                    .tracking(0.7).foregroundStyle(AzaStyle.faint)
            }
            Group {
                switch progress.step {
                case .dictation: dictationExample
                case .correction: correctionExample
                case .clipboard: clipboardDemo
                case .phrases: phraseExample
                case .prayer: prayerExample
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        }
        .padding(20)
        .background(AzaStyle.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AzaStyle.line.opacity(0.7)))
    }

    private var dictationExample: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: phase == 2 ? "checkmark" : "mic.fill")
                    .foregroundStyle(AzaStyle.rise)
                if phase == 1 {
                    TimelineView(.animation(minimumInterval: 0.14, paused: reduceMotion)) { context in
                        HStack(spacing: 4) {
                            ForEach(0..<16) { index in
                                Capsule().fill(AzaStyle.rise)
                                    .frame(width: 3, height: reduceMotion ? 14 :
                                        7 + 17 * abs(sin(context.date.timeIntervalSinceReferenceDate * 4 + Double(index))))
                            }
                        }.frame(height: 28).accessibilityLabel("Пример волны записи")
                    }
                } else {
                    Text(phase == 2 ? "Текст готов" : "Так выглядит запись")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(height: 44).padding(.horizontal, 22)
            .background(.black, in: Capsule())
            Text(phase == 2 ? "Напомни обсудить макет завтра утром." : "«Напомни обсудить макет завтра утром»")
                .font(.system(size: 14)).foregroundStyle(phase == 2 ? AzaStyle.ink : AzaStyle.muted)
                .frame(maxWidth: .infinity, minHeight: 36)
            Button(phase == 0 ? "Показать запись" : phase == 1 ? "Завершить пример" : "Повторить") {
                phase = (phase + 1) % 3
                if phase == 2 { progress.tried(.dictation) }
            }
            .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
            Text("Микрофон в этом примере не используется.")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
        }
    }

    private var correctionExample: some View {
        VStack(spacing: 18) {
            HStack(spacing: 20) {
                Text("ghbdtn").foregroundStyle(AzaStyle.muted)
                Image(systemName: "arrow.right").font(.system(size: 16)).foregroundStyle(AzaStyle.faint)
                Text(phase == 0 ? "…" : "привет").foregroundStyle(AzaStyle.rise)
            }
            .font(.system(size: 27, weight: .medium, design: .monospaced))
            Text(phase == 0 ? "Слово набрано в английской раскладке" : "После пробела Aza исправляет раскладку")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
            Button(phase == 0 ? "Добавить пробел" : "Отменить исправление") {
                phase = phase == 0 ? 1 : 0
                progress.tried(.correction)
            }
            .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
            Text("В приложениях: дважды нажмите правый Shift для отмены.")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
        }
    }

    private var clipboardDemo: some View {
        VStack(spacing: 12) {
            if phase < 2 {
                Label(clipboardExample, systemImage: phase == 0 ? "doc.text" : "checkmark.circle")
                    .font(.system(size: 13)).padding(.vertical, 12)
                Button(phase == 0 ? "Скопировать пример" : "Открыть учебную историю") { phase += 1 }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
            } else {
                TextField("Найти в учебной истории", text: $query).textFieldStyle(.roundedBorder)
                if query.isEmpty || clipboardExample.localizedCaseInsensitiveContains(query) {
                    HStack(spacing: 10) {
                        Text(clipboardExample).font(AzaStyle.body)
                        Spacer(minLength: 4)
                        Button { favorite.toggle() } label: {
                            Image(systemName: favorite ? "star.fill" : "star")
                        }
                        .buttonStyle(.borderless).foregroundStyle(AzaStyle.rise)
                        .accessibilityLabel(favorite ? "Убрать пример из избранного" : "Добавить пример в избранное")
                        Button("Вставить") { phase = 3; progress.tried(.clipboard) }
                            .buttonStyle(AzaCapsuleButtonStyle())
                    }
                } else {
                    Text("Ничего не найдено").font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                }
                if phase == 3 {
                    Label("Вставлено: \(clipboardExample)", systemImage: "checkmark")
                        .font(AzaStyle.caption).foregroundStyle(AzaStyle.rise)
                }
            }
            Text("Настоящий буфер обмена не меняется.")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
        }
    }

    private var phraseExample: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Ваша учебная фраза", text: $phrase).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Учебная фраза")
            if phase > 0 {
                Toggle("Второй вариант · ⇧", isOn: $alternate).toggleStyle(.checkbox)
                    .font(AzaStyle.caption)
                Button {
                    insertedPhrase = alternate ? "Спасибо! Уже смотрю." : phrase
                    phase = 2
                    progress.tried(.phrases)
                } label: {
                    HStack {
                        Text("1").font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(6).background(AzaStyle.control, in: RoundedRectangle(cornerRadius: 5))
                        Text(alternate ? "Спасибо! Уже смотрю." : phrase)
                            .font(AzaStyle.body).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "return").foregroundStyle(AzaStyle.faint)
                    }
                }
                .buttonStyle(.plain).disabled(!alternate && phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if phase == 2 {
                    Label(insertedPhrase, systemImage: "checkmark")
                        .font(AzaStyle.caption).foregroundStyle(AzaStyle.rise)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button("Открыть учебные фразы") { phase = 1 }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
            }
            Text("Изменения здесь не затрагивают ваши сохранённые фразы.")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
        }
    }

    private var prayerExample: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "moon.stars.fill").font(.system(size: 26)).foregroundStyle(AzaStyle.acid)
                VStack(alignment: .leading, spacing: 5) {
                    Text(phase == 0 ? "Следующий намаз" : "Время намаза")
                        .font(.system(size: 14, weight: .semibold))
                    Text(phase == 0 ? "Ваш город · ваше расписание" : "Aza напомнит выбранным способом")
                        .font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                }
            }
            .padding(18).frame(maxWidth: .infinity)
            .background(.black, in: RoundedRectangle(cornerRadius: 18))
            Button(phase == 0 ? "Показать напоминание" : "Повторить") {
                phase = phase == 0 ? 1 : 0
                progress.tried(.prayer)
            }
            .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
            Text("Пример без звука. Настоящее расписание появится после выбора города.")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
                .multilineTextAlignment(.center)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let shortcut = shortcut {
                HStack {
                    Text("В повседневной работе").font(AzaStyle.label)
                    Spacer()
                    Text(shortcut).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(AzaStyle.control, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Text(usage).font(AzaStyle.body).foregroundStyle(AzaStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcut: String? {
        switch progress.step {
        case .dictation: HotKeyBinding.load(HotKeyBinding.dictationKey, fallback: .dictationDefault).display
        case .correction: "правый ⇧ × 2"
        case .clipboard: HotKeyBinding.load(HotKeyBinding.clipboardKey, fallback: .clipboardDefault).display
        case .phrases: "правая ⌥ + 1…0"
        default: nil
        }
    }

    private var usage: String {
        switch progress.step {
        case .dictation:
            "Поставьте курсор в поле, удерживайте сочетание и говорите. Отпустите — текст вставится. Двойное нажатие включает запись без удержания; сочетание, Пробел или Enter остановят её."
        case .correction:
            "Двойной правый Shift отменяет исправление и добавляет слово в исключения. Исправление опечаток, свои слова и приложения-исключения настраиваются отдельно."
        case .clipboard:
            "Откройте историю сочетанием выше, найдите запись и выберите её для вставки. Сейчас срок хранения — \(retentionDays) дней; избранное хранится без срока. Историю можно отключить или очистить в настройках."
        case .phrases:
            "Удерживайте правую ⌥ и нажмите цифру 1–0. Добавьте Shift для второго варианта; фразу можно выбрать кликом. Ещё одно сочетание: \(HotKeyBinding.load(HotKeyBinding.phrasesKey, fallback: .phrasesDefault).display). Свои тексты меняются в настройках."
        case .prayer:
            "Город можно выбрать вручную — геолокация необязательна. Рядом с расписанием указан его источник. Для каждого намаза можно выбрать напоминание и звук. Без уведомлений само расписание остаётся доступным."
        default: ""
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("На вашем Mac").font(AzaStyle.label)
                Spacer()
                Button("Настроить…") { configure(progress.step) }
                    .buttonStyle(AzaCapsuleButtonStyle())
            }
            Text(readiness(progress.step)).font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.muted).fixedSize(horizontal: false, vertical: true)
            if progress.step == .dictation, model.microphone != .authorized {
                if model.microphone == .notDetermined {
                    permissionAction("Микрофон — чтобы записывать речь", button: "Разрешить микрофон") {
                        model.requestMicrophone()
                    }
                } else {
                    Text("Микрофон недоступен. Включите его в Системных настройках → Конфиденциальность и безопасность → Микрофон.")
                        .font(AzaStyle.caption).foregroundStyle(AzaStyle.warning)
                }
            }
            if [.dictation, .correction, .clipboard, .phrases].contains(progress.step), !model.axTrusted {
                permissionAction("Управление компьютером — для вставки и горячих клавиш", button: "Открыть доступ") {
                    model.requestAccessibility()
                }
            }
            if progress.step == .correction, !model.inputMonitoring {
                permissionAction("Мониторинг ввода — для исправлений. После выдачи перезапустите Aza.", button: "Разрешить ввод") {
                    model.requestInputMonitoring()
                }
            }
            if progress.step == .prayer, let issue = model.prayer.notificationIssue {
                Text(issue).font(AzaStyle.caption).foregroundStyle(AzaStyle.warning)
            }
        }
        .padding(16)
        .background(AzaStyle.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func permissionAction(_ explanation: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(explanation).font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action).buttonStyle(AzaCapsuleButtonStyle())
        }
    }

    private func readiness(_ step: Step) -> String {
        switch step {
        case .dictation:
            if let download = model.dictation.downloadProgress, download < 0.999 {
                return "Загрузка модели: \(Int(download * 100))%. Можно продолжить знакомство, пока она скачивается."
            }
            if case .loadingModel = model.dictation.state { return "Модель готовится к работе. Можно продолжить знакомство." }
            let profile = DictationController.preferredProfile
            let cached = DictationController.isModelCached(profile)
            return "Микрофон: \(model.microphone == .authorized ? "доступ есть" : "нужен доступ"). "
                + (cached ? "Модель «\(profile.title)» скачана." : "Выберите и скачайте одну модель в настройках. Для загрузки нужен интернет.")
        case .correction:
            return "Автозамена \(correctionEnabled ? "включена" : "выключена"). "
                + (model.axTrusted && model.inputMonitoring ? "Доступы для исправления выданы." : "Для исправления нужны управление компьютером и мониторинг ввода.")
        case .clipboard:
            return "История \(historyEnabled ? "включена" : "выключена") и хранится на этом Mac. "
                + (model.axTrusted ? "Доступ для вставки выдан." : "Для вставки в другие приложения нужен доступ к управлению компьютером.")
        case .phrases:
            return model.axTrusted ? "Доступ для горячих клавиш и вставки выдан. Добавьте свои фразы в настройках." : "Для горячих клавиш и вставки нужен доступ к управлению компьютером."
        case .prayer:
            guard model.prayer.selectedCityID != nil else { return "Сначала выберите город в настройках. Напоминания включаются отдельно." }
            if let reason = model.prayer.unavailableReason { return reason }
            return "Источник: \(model.prayer.source?.label ?? "расписание"). Напоминания \(model.prayer.notificationsEnabled ? "включены" : "выключены")."
        default: return ""
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                ForEach(Step.features, id: \.self) { step in
                    Button { progress.go(to: step) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: step.symbol).frame(width: 20).foregroundStyle(AzaStyle.rise)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).font(AzaStyle.label)
                                Text(progress.examples.contains(step) ? "Пример пройден" : "Можно попробовать позже")
                                    .font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
                        }
                        .padding(14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if step != .prayer { Divider().overlay(AzaStyle.line.opacity(0.5)) }
                }
            }
            .background(AzaStyle.card, in: RoundedRectangle(cornerRadius: 12))
            Text("Примеры знакомят с возможностями. Доступы и включение функций настраиваются отдельно — их состояние видно на каждом шаге.")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Запускать при входе в macOS", isOn: Binding(
                get: { model.loginItem == .enabled }, set: { model.setLoginItem($0) }))
                .toggleStyle(AzaToggleStyle()).font(AzaStyle.body)
            if let error = model.loginItemError {
                Text("Не удалось изменить автозапуск: \(error)").font(AzaStyle.caption).foregroundStyle(AzaStyle.warning)
            }
            if model.loginItem == .requiresApproval {
                Text("Подтвердите автозапуск в Системных настройках → Элементы входа.")
                    .font(AzaStyle.caption).foregroundStyle(AzaStyle.warning)
            }
            Text("Знакомство всегда доступно: Настройки → Общее → Знакомство с Aza.")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Позже") { close() }.buttonStyle(.plain).foregroundStyle(AzaStyle.muted)
                .help("Закрыть и сохранить место в знакомстве")
            Spacer(minLength: 8)
            if progress.step != .welcome {
                Button("Назад") { progress.move(-1) }.buttonStyle(AzaCapsuleButtonStyle())
            }
            Button(progress.step == .welcome ? "Познакомиться" : progress.step == .finish ? "Начать пользоваться" : "Дальше") {
                if progress.step == .finish {
                    progress.complete()
                    model.showsOnboarding = false
                    close()
                } else { progress.move(1) }
            }
            .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.rise, prominent: true))
            .keyboardShortcut(.defaultAction)
        }
        .font(AzaStyle.label).padding(.horizontal, 28).padding(.vertical, 16)
        .overlay(alignment: .top) { AzaStyle.line.opacity(0.5).frame(height: 1) }
    }

    private func close() {
        NSApp.windows.first { $0.delegate is SetupWindowController }?.performClose(nil)
    }
}
