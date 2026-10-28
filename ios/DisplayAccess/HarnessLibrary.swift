import SwiftUI
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Observation
import MWDATDisplay

struct HarnessDocument: Identifiable, Sendable {
  let url: URL
  var id: String { url.lastPathComponent }
  var title: String { String(url.deletingPathExtension().lastPathComponent.dropFirst(37)) }
}

@Observable @MainActor
final class HarnessLibrary {
  private(set) var documents: [HarnessDocument] = []
  var error: String?
  private let directory: URL

  init() {
    directory = URL.applicationSupportDirectory.appending(path: "HarnessPDFs", directoryHint: .isDirectory)
    reload()
  }

  func reload() {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      documents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .map { HarnessDocument(url: $0) }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    } catch { self.error = error.localizedDescription }
  }

  func importPDF(_ source: URL) {
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    do {
      guard let pdf = PDFDocument(url: source), !pdf.isLocked, pdf.pageCount > 0 else {
        throw HarnessError.invalidPDF
      }
      let name = source.deletingPathExtension().lastPathComponent
      let destination = directory.appendingPathComponent("\(UUID().uuidString)_\(name).pdf")
      try FileManager.default.copyItem(at: source, to: destination)
      reload()
    } catch { self.error = error.localizedDescription }
  }

  func delete(_ offsets: IndexSet) {
    let selected = offsets.map { documents[$0] }
    for document in selected {
      do { try FileManager.default.removeItem(at: document.url) }
      catch { self.error = error.localizedDescription }
    }
    reload()
  }
}

private enum HarnessError: LocalizedError {
  case invalidPDF
  var errorDescription: String? { "Choose an unlocked PDF containing at least one page." }
}

// Render on a worker task. Each task opens its own PDFDocument; PDFKit objects
// are never shared between executors. Only PNG bytes cross the boundary.
private enum HarnessPDFRenderer {
  static func render(url: URL, page index: Int, quadrant: Int?) throws -> Data {
    guard let document = PDFDocument(url: url), !document.isLocked,
          let page = document.page(at: index) else { throw HarnessError.invalidPDF }
    let canvas = CGSize(width: 600, height: 400)
    let image = UIGraphicsImageRenderer(size: canvas, format: {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      return format
    }()).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: canvas))
      let bounds = page.bounds(for: .cropBox)
      let rotation = ((page.rotation % 360) + 360) % 360
      let size = rotation == 90 || rotation == 270
        ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
      guard size.width > 0, size.height > 0 else { return }
      let zoom: CGFloat = quadrant == nil ? 1 : 2
      let scale = min(canvas.width / size.width, canvas.height / size.height) * zoom
      let drawingSize = CGSize(width: size.width * scale, height: size.height * scale)
      var origin = CGPoint(x: (canvas.width - drawingSize.width) / 2,
                           y: (canvas.height - drawingSize.height) / 2)
      if let quadrant {
        origin.x = quadrant % 2 == 0 ? 0 : canvas.width - drawingSize.width
        origin.y = quadrant < 2 ? 0 : canvas.height - drawingSize.height
      }
      // PDFKit thumbnails honor crop and rotation. Bound the raster to 1200×800.
      let thumbnail = page.thumbnail(of: drawingSize, for: .cropBox)
      thumbnail.draw(in: CGRect(origin: origin, size: drawingSize))
    }
    guard let data = image.pngData() else { throw HarnessError.invalidPDF }
    return data
  }
}

@Observable @MainActor
final class HarnessReader {
  var image: UIImage?
  var status = "Choose a PDF to preview it."
  var busy = false
  private var selected: HarnessDocument?
  private var page = 0
  private var pages = 0
  private var quadrant: Int?
  private var generation = UUID()

  func open(_ document: HarnessDocument, display: DisplayViewModel) async {
    guard !busy, !display.isSending else { return }
    guard let pdf = PDFDocument(url: document.url), !pdf.isLocked, pdf.pageCount > 0 else {
      status = HarnessError.invalidPDF.localizedDescription
      return
    }
    selected = document
    page = 0
    pages = pdf.pageCount
    quadrant = nil
    await show(display)
  }

  func menu(_ library: HarnessLibrary, display: DisplayViewModel, index: Int = 0) async {
    guard !busy, !display.isSending else { return }
    generation = UUID()
    let documents = library.documents
    let start = min(max(index, 0), max(documents.count - 1, 0))
    await display.send(
      FlexBox(direction: .column, spacing: 8) {
        MWDATDisplay.Text("Harness documents", style: .heading)
        if documents.isEmpty {
          MWDATDisplay.Text("Import PDFs on your iPhone first.", style: .body)
        } else {
          MWDATDisplay.Text("\(start + 1)–\(min(start + 3, documents.count)) of \(documents.count)", style: .body)
          ButtonGroup {
            for document in documents.dropFirst(start).prefix(3) {
              MWDATDisplay.Button(label: String(document.title.prefix(40)), style: .primary, onClick: {
                Task { @MainActor in await self.open(document, display: display) }
              })
            }
          }
          ButtonGroup {
            if start > 0 {
              MWDATDisplay.Button(label: "Previous", style: .secondary, onClick: {
                Task { @MainActor in await self.menu(library, display: display, index: max(0, start - 3)) }
              })
            }
            if start + 3 < documents.count {
              MWDATDisplay.Button(label: "More", style: .secondary, onClick: {
                Task { @MainActor in await self.menu(library, display: display, index: start + 3) }
              })
            }
          }
        }
      }.padding(16)
    )
  }

  func show(_ display: DisplayViewModel) async {
    guard let selected, !busy, !display.isSending else { return }
    busy = true
    defer { busy = false }
    let request = UUID()
    generation = request
    let url = selected.url, index = page, crop = quadrant
    do {
      let data = try await Task.detached(priority: .userInitiated) {
        try HarnessPDFRenderer.render(url: url, page: index, quadrant: crop)
      }.value
      guard request == generation, let rendered = UIImage(data: data) else { return }
      image = rendered
      status = "\(selected.title) · \(page + 1)/\(pages)" + (crop.map { " · section \($0 + 1)/4" } ?? "")
      await display.send(
        FlexBox(direction: .column, spacing: 4) {
          MWDATDisplay.Text("\(page + 1)/\(pages) · \(String(selected.title.prefix(30)))", style: .body)
          MWDATDisplay.Image(image: rendered, sizePreset: .fill).flexShrink(1)
          ButtonGroup {
            if page > 0 {
              MWDATDisplay.Button(label: "Previous", style: .secondary, onClick: {
                Task { @MainActor in await self.turn(-1, display: display) }
              })
            }
            if page + 1 < pages {
              MWDATDisplay.Button(label: "Next", style: .primary, onClick: {
                Task { @MainActor in await self.turn(1, display: display) }
              }).actionRole(.primary)
            }
            MWDATDisplay.Button(label: quadrant == nil ? "Zoom" : "Next section", style: .secondary, onClick: {
              Task { @MainActor in
                guard !self.busy, !display.isSending else { return }
                self.quadrant = self.quadrant.map { ($0 + 1) % 4 }
                  ?? 0
                await self.show(display)
              }
            })
          }
          ButtonGroup {
            if quadrant != nil {
              MWDATDisplay.Button(label: "Fit page", style: .secondary, onClick: {
                Task { @MainActor in
                  guard !self.busy, !display.isSending else { return }
                  self.quadrant = nil
                  await self.show(display)
                }
              })
            }
            MWDATDisplay.Button(label: "Documents", style: .secondary, onClick: {
              Task { @MainActor in await self.menu(HarnessLibrary(), display: display) }
            })
          }
        }.padding(8)
      )
    } catch { status = error.localizedDescription }
  }

  func turn(_ delta: Int, display: DisplayViewModel) async {
    guard !busy, !display.isSending else { return }
    page = min(max(page + delta, 0), max(pages - 1, 0))
    quadrant = nil
    await show(display)
  }
}

struct HarnessLibraryView: View {
  var display: DisplayViewModel
  @State private var library = HarnessLibrary()
  @State private var reader = HarnessReader()
  @State private var importing = false

  var body: some View {
    List {
      Section {
        SwiftUI.Button("Import PDFs from Files / Google Drive") { importing = true }
        SwiftUI.Button("Show document menu on glasses") {
          Task { await reader.menu(library, display: display) }
        }.disabled(reader.busy || display.isSending)
        SwiftUI.Button("Disconnect display") {
          Task {
            do { try await display.stopSession() }
            catch { library.error = error.localizedDescription }
          }
        }.disabled(reader.busy || display.isSending)
      } footer: {
        SwiftUI.Text("Import once on your phone. Then choose documents on the glasses. Copies stay on this phone; Drive changes are not synced.")
      }
      Section("Saved PDFs") {
        if library.documents.isEmpty { SwiftUI.Text("No PDFs imported yet.").foregroundStyle(.secondary) }
        ForEach(library.documents) { document in
          SwiftUI.Button(document.title) { Task { await reader.open(document, display: display) } }
            .disabled(reader.busy || display.isSending)
        }.onDelete(perform: library.delete)
      }
      Section("Page preview") {
        SwiftUI.Text(reader.status)
        if reader.busy || display.isSending { ProgressView("Preparing display…") }
        if let image = reader.image {
          SwiftUI.Image(uiImage: image).resizable().scaledToFit()
          HStack {
            SwiftUI.Button("Previous page") { Task { await reader.turn(-1, display: display) } }
            Spacer()
            SwiftUI.Button("Next page") { Task { await reader.turn(1, display: display) } }
          }.disabled(reader.busy || display.isSending)
        }
        if let error = display.errorMessage { SwiftUI.Text(error).foregroundStyle(.red) }
      }
    }
    .navigationTitle("Harness PDFs")
    .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
      switch result {
      case .success(let urls): urls.forEach(library.importPDF)
      case .failure(let error): library.error = error.localizedDescription
      }
    }
    .alert("PDF library", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
      SwiftUI.Button("OK") { library.error = nil }
    } message: { SwiftUI.Text(library.error ?? "") }
  }
}
