import SwiftUI

/// Выбор города: кнопка + поповер с поиском. Системное меню на сотню
/// позиций (наши города + каталог ДУМ) не пролистать — нужен фильтр.
struct CityPickerView: View {
    /// Пустая строка — город не выбран; договорённость общая с @AppStorage.
    @Binding var cityID: String
    let cities: [PrayerCity]

    @State private var isOpen = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var selectedName: String {
        cities.first { $0.id == cityID }?.name ?? "Город не выбран"
    }

    private var filtered: [PrayerCity] {
        query.isEmpty ? cities : cities.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Button {
            query = ""
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
            VStack(spacing: 0) {
                TextField("Поиск города", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit {
                        guard let first = filtered.first else { return }
                        cityID = first.id
                        isOpen = false
                    }
                    .padding(8)
                Divider()
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
            }
            .frame(width: 240, height: 300)
            .onAppear { searchFocused = true }
        }
    }

    private func row(id: String, name: String) -> some View {
        Button {
            cityID = id
            isOpen = false
        } label: {
            HStack {
                Text(name)
                Spacer()
                if id == cityID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}
