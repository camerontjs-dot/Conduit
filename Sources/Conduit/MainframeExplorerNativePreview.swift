#if canImport(AppKit)
import AppKit
import ImageIO
import PDFKit
import SwiftUI

enum MainframeExplorerNativePreviewError: LocalizedError {
    case imageDecodeFailed
    case imageTooLarge
    case pdfDecodeFailed
    case lockedPDF

    var errorDescription: String? {
        switch self {
        case .imageDecodeFailed: return "macOS could not decode this file as an image."
        case .imageTooLarge: return "This image exceeds the 40 million pixel preview limit. Open it externally to inspect it."
        case .pdfDecodeFailed: return "PDFKit could not decode a document with readable pages from this file."
        case .lockedPDF: return "This PDF is password protected. Open it externally to unlock it."
        }
    }
}

/// Native decoders consume the authorized byte snapshot, never the source URL.
enum MainframeExplorerNativeDecoder {
    static func image(data: Data) throws -> NSImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw MainframeExplorerNativePreviewError.imageDecodeFailed
        }
        let pixels = width.doubleValue * height.doubleValue
        guard pixels.isFinite, pixels > 0, pixels <= 40_000_000 else {
            throw MainframeExplorerNativePreviewError.imageTooLarge
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MainframeExplorerNativePreviewError.imageDecodeFailed
        }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
    }

    static func pdf(data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw MainframeExplorerNativePreviewError.pdfDecodeFailed
        }
        guard !document.isLocked else { throw MainframeExplorerNativePreviewError.lockedPDF }
        guard document.pageCount > 0 else { throw MainframeExplorerNativePreviewError.pdfDecodeFailed }
        return document
    }
}

@MainActor
private final class MainframeExplorerImageModel: ObservableObject {
    let image: NSImage?
    let error: String?

    init(data: Data) {
        do {
            image = try MainframeExplorerNativeDecoder.image(data: data)
            error = nil
        } catch {
            image = nil
            self.error = error.localizedDescription
        }
    }
}

@MainActor
struct MainframeExplorerImagePreview: View {
    let name: String
    @StateObject private var model: MainframeExplorerImageModel
    @State private var manualScale: CGFloat?
    @State private var viewport: CGSize = .zero

    init(data: Data, name: String) {
        self.name = name
        _model = StateObject(wrappedValue: MainframeExplorerImageModel(data: data))
    }

    var body: some View {
        if let image = model.image {
            VStack(spacing: 0) {
                HStack {
                    Button("Fit") { manualScale = nil }
                        .accessibilityIdentifier("explorer.preview.image.fit")
                    Button("100%") { manualScale = 1 }
                        .accessibilityIdentifier("explorer.preview.image.actual")
                    Button { zoom(by: 0.8, image: image) } label: { Image(systemName: "minus.magnifyingglass") }
                        .accessibilityLabel("Zoom image out")
                        .accessibilityIdentifier("explorer.preview.image.zoom-out")
                    Button { zoom(by: 1.25, image: image) } label: { Image(systemName: "plus.magnifyingglass") }
                        .accessibilityLabel("Zoom image in")
                        .accessibilityIdentifier("explorer.preview.image.zoom-in")
                    Text(manualScale.map { "\(Int(($0 * 100).rounded()))%" } ?? "Fit")
                        .monospacedDigit()
                    Spacer()
                    Text("Static image · \(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                GeometryReader { geometry in
                    let scale = manualScale ?? fitScale(image: image, viewport: geometry.size)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable().interpolation(.high)
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                            .accessibilityLabel("Image preview for \(name)")
                    }
                    .onAppear { viewport = geometry.size }
                    .onChange(of: geometry.size) { viewport = $0 }
                }
            }
        } else {
            previewFailure(model.error ?? "Image preview is unavailable.")
        }
    }

    private func fitScale(image: NSImage, viewport: CGSize) -> CGFloat {
        guard viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / image.size.width, viewport.height / image.size.height)
    }

    private func zoom(by factor: CGFloat, image: NSImage) {
        manualScale = min(8, max(0.05, (manualScale ?? fitScale(image: image, viewport: viewport)) * factor))
    }
}

@MainActor
final class MainframeExplorerPDFController: NSObject, ObservableObject {
    let view = PDFView()
    let document: PDFDocument
    @Published private(set) var pageNumber = 1
    @Published private(set) var zoomPercent = 100

    init(document: PDFDocument) {
        self.document = document
        super.init()
        view.minScaleFactor = 0.05
        view.maxScaleFactor = 8
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .textBackgroundColor
        view.document = document
        view.autoScales = true
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .PDFViewPageChanged, object: view)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .PDFViewScaleChanged, object: view)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func go(to index: Int) {
        guard let page = document.page(at: index) else { return }
        view.go(to: page)
        sync()
    }

    func fit() {
        view.autoScales = true
        sync()
    }

    func zoom(by factor: CGFloat) {
        view.autoScales = false
        view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, view.scaleFactor * factor))
        sync()
    }

    @objc private func changed(_ notification: Notification) {
        // PDFKit also posts notifications while laying out its native view.
        Task { @MainActor [weak self] in self?.sync() }
    }

    private func sync() {
        if let page = view.currentPage { pageNumber = document.index(for: page) + 1 }
        zoomPercent = Int((view.scaleFactor * 100).rounded())
    }
}

@MainActor
struct MainframeExplorerPDFPreview: View {
    let name: String
    @StateObject private var model: MainframeExplorerPDFModel

    init(data: Data, name: String) {
        self.name = name
        _model = StateObject(wrappedValue: MainframeExplorerPDFModel(data: data))
    }

    var body: some View {
        if let controller = model.controller {
            MainframeExplorerPDFControls(controller: controller, name: name)
        } else {
            previewFailure(model.error ?? "PDF preview is unavailable.")
        }
    }
}

@MainActor
private final class MainframeExplorerPDFModel: ObservableObject {
    let controller: MainframeExplorerPDFController?
    let error: String?

    init(data: Data) {
        do {
            controller = MainframeExplorerPDFController(document: try MainframeExplorerNativeDecoder.pdf(data: data))
            error = nil
        } catch {
            controller = nil
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private struct MainframeExplorerPDFControls: View {
    @ObservedObject var controller: MainframeExplorerPDFController
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { controller.go(to: controller.pageNumber - 2) } label: { Image(systemName: "chevron.left") }
                    .disabled(controller.pageNumber <= 1)
                    .accessibilityLabel("Previous PDF page")
                    .accessibilityIdentifier("explorer.preview.pdf.previous")
                Text("Page \(controller.pageNumber) of \(controller.document.pageCount)").monospacedDigit()
                    .accessibilityIdentifier("explorer.preview.pdf.page")
                Button { controller.go(to: controller.pageNumber) } label: { Image(systemName: "chevron.right") }
                    .disabled(controller.pageNumber >= controller.document.pageCount)
                    .accessibilityLabel("Next PDF page")
                    .accessibilityIdentifier("explorer.preview.pdf.next")
                Spacer()
                Button("Fit") { controller.fit() }
                    .accessibilityIdentifier("explorer.preview.pdf.fit")
                Button { controller.zoom(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Zoom PDF out")
                    .accessibilityIdentifier("explorer.preview.pdf.zoom-out")
                Text("\(controller.zoomPercent)%").monospacedDigit()
                Button { controller.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Zoom PDF in")
                    .accessibilityIdentifier("explorer.preview.pdf.zoom-in")
            }
            .padding(8)
            MainframeExplorerPDFCanvas(view: controller.view)
                .accessibilityLabel("PDF preview for \(name)")
        }
    }
}

@MainActor
private struct MainframeExplorerPDFCanvas: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ view: PDFView, context: Context) {}
}

@MainActor
private func previewFailure(_ message: String) -> some View {
    VStack(alignment: .leading) {
        Label(message, systemImage: "doc.badge.ellipsis")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityIdentifier("explorer.preview.unavailable")
}
#endif
