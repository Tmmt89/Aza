import AppKit

enum PasteboardCategories {
    static func labels(for types: Set<NSPasteboard.PasteboardType>) -> [String] {
        var result: [String] = []
        if types.contains(.string) { result.append("текст") }
        if !types.isDisjoint(with: [.rtf, .rtfd, .html]) { result.append("форматированный текст") }
        if types.contains(.URL) { result.append("ссылка") }
        if !types.isDisjoint(with: [.png, .tiff]) { result.append("изображение") }
        if types.contains(.fileURL) { result.append("файл/папка") }
        return result
    }
}
