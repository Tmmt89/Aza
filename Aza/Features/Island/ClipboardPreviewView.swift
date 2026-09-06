import AppKit
import QuickLookUI
import SwiftUI

/// Содержимое остаётся в памяти: для изображений читаем зашифрованный
/// оригинал, Quick Look получает только уже существующие файлы.
struct ClipboardPreviewView: View {
    let entry: ClipEntry
    let imageData: () -> Data?
    let close: () -> Void
    @State private var image: NSImage?
    @State private var fileIndex = 0

    private var paths: [String] { entry.filePaths ?? [] }
    private var isText: Bool { ![.image, .files].contains(entry.resolvedKind) }
    private var size: CGSize {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        let available = screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        return CGSize(width: min(isText ? 520 : 600, available.width - 60),
                      height: min(isText ? 300 : 440, available.height * 0.55))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: entry.islandKind.symbol)
                Text(entry.islandKind.title).fontWeight(.semibold)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Закрыть предпросмотр")
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Group {
                if entry.resolvedKind == .image {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                            .padding(8)
                            .accessibilityLabel("Полное изображение")
                    } else {
                        Text("Изображение недоступно").foregroundStyle(.secondary)
                    }
                } else if entry.resolvedKind == .files {
                    if paths.indices.contains(fileIndex) {
                        let path = paths[fileIndex]
                        if FileManager.default.fileExists(atPath: path) {
                            ClipboardFilePreview(url: URL(fileURLWithPath: path)).id(path)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "doc.badge.ellipsis").font(.largeTitle)
                                Text("Файл перемещён или удалён")
                                Text(path).font(.caption).textSelection(.enabled)
                            }.foregroundStyle(.secondary).padding()
                        }
                    } else {
                        Text("Нет файлов для предпросмотра").foregroundStyle(.secondary)
                    }
                } else {
                    ClipboardTextPreview(text: entry.text, rtf: entry.rtfData)
                }
            }
            .frame(width: size.width, height: size.height)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 6)

            HStack(spacing: 8) {
                if entry.resolvedKind == .files, !paths.isEmpty {
                    Text(URL(fileURLWithPath: paths[fileIndex]).lastPathComponent).lineLimit(1)
                    Spacer()
                    if paths.count > 1 {
                        Button { fileIndex -= 1 } label: { Image(systemName: "chevron.left") }
                            .disabled(fileIndex == 0).accessibilityLabel("Предыдущий файл")
                        Text("\(fileIndex + 1) / \(paths.count)").monospacedDigit()
                        Button { fileIndex += 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(fileIndex == paths.count - 1).accessibilityLabel("Следующий файл")
                    }
                } else {
                    if let rep = image?.representations.first {
                        Text("\(rep.pixelsWide) × \(rep.pixelsHigh)")
                    } else if isText {
                        Text("Символов: \(entry.text.count)")
                    }
                    Spacer()
                    Text(entry.sourceApp).lineLimit(1)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .buttonStyle(.plain).padding(12)
        }
        .background(.regularMaterial)
        .preferredColorScheme(.light)
        .task(id: entry.id) {
            if entry.resolvedKind == .image { image = imageData().flatMap(NSImage.init(data:)) }
        }
    }
}

struct ClipboardTextPreview: NSViewRepresentable {
    let text: String
    let rtf: Data?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.backgroundColor = .white
        if let rtf, let rich = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            view.textStorage?.setAttributedString(rich)
        } else {
            view.string = text
            view.font = .systemFont(ofSize: 14)
        }
        view.textColor = .black
        view.setAccessibilityLabel("Полный текст")
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

private struct ClipboardFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}
