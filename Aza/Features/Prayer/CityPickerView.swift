import SwiftUI

/// Выбор города: кнопка + поповер с поиском. Системное меню на сотню
/// позиций (наши города + каталог ДУМ) не пролистать — нужен фильтр.
struct CityPickerView: View {
    /// Пустая строка — город не выбран; договорённость общая с @AppStorage.
    @Binding var cityID: String
    let cities: [PrayerCity]

    @State private var isOpen = false

    private var selectedName: String {
        cities.first { $0.id == cityID }?.name ?? "Город не выбран"
    }

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 5) {
                Text(selectedName)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            CityPickerList(cityID: $cityID, cities: cities, dismiss: { isOpen = false })
        }
    }
}

/// Содержимое поповера: поиск + список. Отдельная вью, чтобы её можно
/// было показать и без поповера (превью, скриншоты).
struct CityPickerList: View {
    @Binding var cityID: String
    let cities: [PrayerCity]
    var dismiss: () -> Void = {}

    @State private var query = ""
    @State private var hoveredID: String?
    @FocusState private var searchFocused: Bool

    private var filtered: [PrayerCity] {
        query.isEmpty ? cities : cities.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private func choose(_ id: String) {
        cityID = id
        dismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Поиск города", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    guard let first = filtered.first else { return }
                    choose(first.id)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AzaStyle.control, in: RoundedRectangle(
                    cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(searchFocused ? AzaStyle.rise.opacity(0.6) : AzaStyle.line))
                .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if query.isEmpty {
                            row(id: "", name: "Город не выбран")
                        }
                        ForEach(filtered) { city in
                            row(id: city.id, name: city.name)
                        }
                        if filtered.isEmpty {
                            Text("Ничего не найдено")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Открылся — выбранный город виден, а не где-то за
                // экраном в середине алфавита.
                .onAppear { proxy.scrollTo(cityID, anchor: .center) }
            }
        }
        .frame(width: 240, height: 300)
        .tint(AzaStyle.rise)
        .onAppear { searchFocused = true }
    }

    private func row(id: String, name: String) -> some View {
        Button {
            choose(id)
        } label: {
            HStack {
                Text(name)
                Spacer()
                if id == cityID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AzaStyle.rise)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .id(id)
        .background(hoveredID == id ? Color.primary.opacity(0.08) : .clear)
        .onHover { hoveredID = $0 ? id : (hoveredID == id ? nil : hoveredID) }
    }
}
