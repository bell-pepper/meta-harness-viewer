import SwiftUI
import PDFKit
import UIKit
import CoreImage
import UniformTypeIdentifiers
import Observation
import MWDATDisplay

struct HarnessLocation: Codable, Identifiable, Sendable {
  let id: UUID
  let name: String
  let bookmark: Data
  let isFolder: Bool
}

struct HarnessDocument: Identifiable, Sendable {
  let location: HarnessLocation
  let path: [String]
  let isFolder: Bool
  var id: String { location.id.uuidString + "/" + path.joined(separator: "/") }
  var title: String {
    let name = path.last ?? location.name
    return isFolder ? name : (name as NSString).deletingPathExtension
  }
  var parent: HarnessDocument? {
    guard !path.isEmpty else { return nil }
    return HarnessDocument(location: location, path: Array(path.dropLast()), isFolder: true)
  }
}

private enum HarnessError: LocalizedError {
  case invalidPDF, unavailable, invalidFolder, changedDocument
  var errorDescription: String? {
    switch self {
    case .invalidPDF: "Choose an unlocked PDF containing at least one page."
    case .unavailable: "This location is unavailable. Check Drive/Files on your phone, then select the location again if needed."
    case .invalidFolder: "This provider cannot open the selected folder. Choose individual PDFs instead."
    case .changedDocument: "The PDF changed or that page is unavailable. Reopen it from Documents."
    }
  }
}

// A saved bookmark is a reference, not a PDF copy. Resolve it and hold the
// selected root's security scope while coordinating each provider operation.
private enum HarnessFiles {
  static func coordinate<T>(_ document: HarnessDocument, operation: (URL) throws -> T) throws -> T {
    var stale = false
    let root: URL
    do {
      root = try URL(resolvingBookmarkData: document.location.bookmark,
                     options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    } catch { throw HarnessError.unavailable }
    let granted = root.startAccessingSecurityScopedResource()
    defer { if granted { root.stopAccessingSecurityScopedResource() } }
    // Never trust a saved relative path to escape its selected root.
    guard document.path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else {
      throw HarnessError.unavailable
    }
    let target = document.path.reduce(root) { $0.appendingPathComponent($1) }
    var result: Result<T, Error>?
    var coordinationError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: target, options: [], error: &coordinationError) { url in
      result = Result { try operation(url) }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw HarnessError.unavailable }
    return try result.get()
  }

  static func remember(_ source: URL, folder: Bool) throws -> HarnessLocation {
    let granted = source.startAccessingSecurityScopedResource()
    defer { if granted { source.stopAccessingSecurityScopedResource() } }
    let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isSymbolicLink != true else { throw HarnessError.unavailable }
    if folder {
      guard values.isDirectory == true else { throw HarnessError.invalidFolder }
    } else {
      guard values.isDirectory != true, source.pathExtension.lowercased() == "pdf" else { throw HarnessError.invalidPDF }
    }
    // Creating a bookmark does not parse/download the entire PDF into our app.
    let bookmark = try source.bookmarkData(options: [.minimalBookmark],
                                          includingResourceValuesForKeys: nil, relativeTo: nil)
    return HarnessLocation(id: UUID(), name: source.lastPathComponent, bookmark: bookmark, isFolder: folder)
  }

  static func children(of folder: HarnessDocument) throws -> [HarnessDocument] {
    try coordinate(folder) { url in
      let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
      let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
                                                            options: [.skipsHiddenFiles])
      return try urls.compactMap { child -> HarnessDocument? in
        let values = try child.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { return nil }
        let isFolder = values.isDirectory == true
        guard isFolder || child.pathExtension.lowercased() == "pdf" else { return nil }
        return HarnessDocument(location: folder.location, path: folder.path + [child.lastPathComponent], isFolder: isFolder)
      }.sorted {
        if $0.isFolder != $1.isFolder { return $0.isFolder }
        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
    }
  }
}

@Observable @MainActor
final class HarnessLibrary {
  private(set) var locations: [HarnessLocation] = []
  var error: String?
  var busy = false
  private let metadataURL = URL.applicationSupportDirectory.appending(path: "HarnessLocations.json")

  init() {
    do {
      if FileManager.default.fileExists(atPath: metadataURL.path) {
        locations = try JSONDecoder().decode([HarnessLocation].self, from: Data(contentsOf: metadataURL))
      }
    } catch { self.error = "Saved locations could not be read. \(error.localizedDescription)" }
  }

  private func save(_ updated: [HarnessLocation]) throws {
    try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(updated).write(to: metadataURL, options: .atomic)
    locations = updated
  }

  func select(_ urls: [URL], folders: Bool) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    for url in urls {
      do {
        let location = try await Task.detached(priority: .userInitiated) {
          try HarnessFiles.remember(url, folder: folders)
        }.value
        try save(locations + [location])
      } catch { self.error = error.localizedDescription }
    }
  }

  func forget(_ offsets: IndexSet) {
    do {
      let updated = locations.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
      try save(updated)
    } catch { self.error = error.localizedDescription }
    // Forgetting a reference never deletes a file or folder in Drive/Files.
  }

  func entries(in folder: HarnessDocument?) async throws -> [HarnessDocument] {
    guard let folder else {
      return locations.map { HarnessDocument(location: $0, path: [], isFolder: $0.isFolder) }
    }
    guard folder.isFolder else { throw HarnessError.invalidFolder }
    return try await Task.detached(priority: .userInitiated) { try HarnessFiles.children(of: folder) }.value
  }
}

// PDFKit objects stay inside a worker operation. Only small raster PNG bytes
// cross to the main actor; no PDF or page raster is written into app storage.
private enum HarnessPDFRenderer {
  static func count(_ document: HarnessDocument) throws -> Int {
    try HarnessFiles.coordinate(document) { url in
      guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { throw HarnessError.invalidPDF }
      return pdf.pageCount
    }
  }

  static func render(_ document: HarnessDocument, page index: Int, quadrant: Int?) throws -> Data {
    try HarnessFiles.coordinate(document) { url in
      guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw HarnessError.invalidPDF }
      guard let page = pdf.page(at: index) else { throw HarnessError.changedDocument }
      let canvas = CGSize(width: 600, height: 600)
      let bounds = page.bounds(for: .cropBox)
      let rotation = ((page.rotation % 360) + 360) % 360
      let size = rotation == 90 || rotation == 270
        ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
      guard size.width > 0, size.height > 0 else { throw HarnessError.invalidPDF }
      let zoom: CGFloat = quadrant == nil ? 1 : 2
      let scale = min(canvas.width / size.width, canvas.height / size.height) * zoom
      let drawingSize = CGSize(width: size.width * scale, height: size.height * scale)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let raster = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: canvas))
        var origin = CGPoint(x: (canvas.width - drawingSize.width) / 2, y: (canvas.height - drawingSize.height) / 2)
        if let quadrant {
          origin.x = drawingSize.width <= canvas.width ? (canvas.width - drawingSize.width) / 2
            : quadrant % 2 == 0 ? 0 : canvas.width - drawingSize.width
          origin.y = drawingSize.height <= canvas.height ? (canvas.height - drawingSize.height) / 2
            : quadrant < 2 ? 0 : canvas.height - drawingSize.height
        }
        page.thumbnail(of: drawingSize, for: .cropBox).draw(in: CGRect(origin: origin, size: drawingSize))
      }
      guard let input = CIImage(image: raster),
            let output = CIContext(options: [.cacheIntermediates: false]).createCGImage(
              input.applyingFilter("CIColorInvert"), from: input.extent),
            let png = UIImage(cgImage: output).pngData() else { throw HarnessError.invalidPDF }
      return png
    }
  }
}

@Observable @MainActor
final class HarnessReader {
  var image: UIImage?
  var status = "Choose PDFs or a folder on your phone."
  var busy = false
  private var selected: HarnessDocument?
  private var folder: HarnessDocument?
  private var menuIndex = 0
  private var library: HarnessLibrary?
  private var page = 0
  private var pages = 0
  private var quadrant: Int?

  func open(_ document: HarnessDocument, library: HarnessLibrary, display: DisplayViewModel) async {
    guard !busy, !display.isSending else { return }
    if document.isFolder { await menu(library, display: display, folder: document); return }
    self.library = library
    if self.folder?.id != document.parent?.id { menuIndex = 0 }
    self.folder = document.parent
    selected = nil
    image = nil
    busy = true
    status = "Opening \(document.title)… Drive may need to download it."
    do {
      let count = try await Task.detached(priority: .userInitiated) { try HarnessPDFRenderer.count(document) }.value
      selected = document
      page = 0
      pages = count
      quadrant = nil
      busy = false
      await show(display)
    } catch {
      busy = false
      await showFailure(error, library: library, display: display)
    }
  }

  func menu(_ library: HarnessLibrary, display: DisplayViewModel, folder: HarnessDocument? = nil, index: Int = 0) async {
    guard !busy, !display.isSending else { return }
    self.library = library
    busy = true
    defer { busy = false }
    image = nil
    do {
      let entries = try await library.entries(in: folder)
      self.folder = folder
      selected = nil
      let start = min(max(index, 0), max(entries.count - 1, 0))
      menuIndex = start
      status = folder?.title ?? "Selected locations"
      await display.send(
        FlexBox(direction: .column, spacing: 8) {
          MWDATDisplay.Text(folder?.title ?? "Harness files", style: .heading)
          if entries.isEmpty {
            MWDATDisplay.Text(folder == nil ? "Choose PDFs or a folder on your iPhone first." : "No PDF files or subfolders here.", style: .body)
          } else {
            MWDATDisplay.Text("\(start + 1)–\(min(start + 3, entries.count)) of \(entries.count)", style: .body)
            for entry in entries.dropFirst(start).prefix(3) {
              ButtonGroup {
                MWDATDisplay.Button(label: String(((entry.isFolder ? "Folder: " : "") + entry.title).prefix(44)), style: .primary, onClick: {
                  Task { @MainActor in await self.open(entry, library: library, display: display) }
                })
              }
            }
          }
          ButtonGroup {
            if start > 0 {
              MWDATDisplay.Button(label: "Previous", style: .secondary, onClick: {
                Task { @MainActor in await self.menu(library, display: display, folder: folder, index: max(0, start - 3)) }
              })
            }
            if start + 3 < entries.count {
              MWDATDisplay.Button(label: "More", style: .secondary, onClick: {
                Task { @MainActor in await self.menu(library, display: display, folder: folder, index: start + 3) }
              })
            }
            if let folder {
              MWDATDisplay.Button(label: "Up", style: .secondary, onClick: {
                Task { @MainActor in await self.menu(library, display: display, folder: folder.parent) }
              })
            }
            MWDATDisplay.Button(label: "Refresh", style: .secondary, onClick: {
              Task { @MainActor in await self.menu(library, display: display, folder: folder, index: start) }
            })
          }
        }.padding(16)
      )
    } catch { await showFailure(error, library: library, display: display) }
  }

  private func showFailure(_ error: Error, library: HarnessLibrary, display: DisplayViewModel) async {
    status = error.localizedDescription
    await display.send(
      FlexBox(direction: .column, spacing: 12) {
        MWDATDisplay.Text("Could not open location", style: .heading)
        MWDATDisplay.Text("Check Files or Drive on your phone. Re-select the location if access expired.", style: .body)
        ButtonGroup {
          MWDATDisplay.Button(label: "Locations", onClick: {
            Task { @MainActor in await self.menu(library, display: display) }
          })
        }
      }.padding(16)
    )
  }

  func show(_ display: DisplayViewModel) async {
    guard let selected, !busy, !display.isSending else { return }
    busy = true
    defer { busy = false }
    let index = page, crop = quadrant
    do {
      let data = try await Task.detached(priority: .userInitiated) {
        try HarnessPDFRenderer.render(selected, page: index, quadrant: crop)
      }.value
      guard let rendered = UIImage(data: data) else { throw HarnessError.invalidPDF }
      image = rendered
      status = "\(selected.title) · \(page + 1)/\(pages)" + (crop.map { " · section \($0 + 1)/4" } ?? "")
      // Reading view sends only a page image. Select/tap opens controls.
      await display.send(
        FlexBox(direction: .column) {
          MWDATDisplay.Image(image: rendered, sizePreset: .fill)
        }.padding(0).onTap {
          Task { @MainActor in await self.controls(display) }
        }
      )
    } catch {
      if let library { await showFailure(error, library: library, display: display) }
      else { status = error.localizedDescription }
    }
  }

  func controls(_ display: DisplayViewModel) async {
    guard let selected, !busy, !display.isSending else { return }
    await display.send(
      FlexBox(direction: .column, spacing: 12) {
        MWDATDisplay.Text(selected.title, style: .heading)
        MWDATDisplay.Text("Page \(page + 1) of \(pages)", style: .body)
        ButtonGroup {
          if page > 0 {
            MWDATDisplay.Button(label: "Previous", onClick: { Task { @MainActor in await self.turn(-1, display: display) } })
          }
          if page + 1 < pages {
            MWDATDisplay.Button(label: "Next", onClick: { Task { @MainActor in await self.turn(1, display: display) } })
          }
          MWDATDisplay.Button(label: quadrant == nil ? "Zoom" : "Next section", onClick: {
            Task { @MainActor in
              guard !self.busy, !display.isSending else { return }
              self.quadrant = self.quadrant.map { ($0 + 1) % 4 } ?? 0
              await self.show(display)
            }
          })
        }
        ButtonGroup {
          MWDATDisplay.Button(label: "Fit page", onClick: {
            Task { @MainActor in
              guard !self.busy, !display.isSending else { return }
              self.quadrant = nil
              await self.show(display)
            }
          })
          MWDATDisplay.Button(label: "Documents", onClick: {
            Task { @MainActor in
              if let library = self.library { await self.menu(library, display: display, folder: self.folder, index: self.menuIndex) }
            }
          })
          MWDATDisplay.Button(label: "Read", onClick: { Task { @MainActor in await self.show(display) } }).actionRole(.primary)
        }
      }.padding(16)
    )
  }

  func turn(_ delta: Int, display: DisplayViewModel) async {
    guard !busy, !display.isSending else { return }
    page = min(max(page + delta, 0), max(pages - 1, 0))
    quadrant = nil
    await show(display)
  }

  func release() {
    image = nil
    selected = nil
    status = "Page preview released. Files/Drive may keep its own cached download."
  }
}

struct HarnessLibraryView: View {
  var display: DisplayViewModel
  @State private var library = HarnessLibrary()
  @State private var reader = HarnessReader()
  @State private var picking = false
  @State private var pickingFolders = false

  var body: some View {
    List {
      Section {
        SwiftUI.Button("Choose PDFs from Files / Drive") { pickingFolders = false; picking = true }
        SwiftUI.Button("Choose a folder") { pickingFolders = true; picking = true }
        SwiftUI.Button("Browse on glasses") { Task { await reader.menu(library, display: display) } }
        SwiftUI.Button("Show reading controls") { Task { await reader.controls(display) } }
        SwiftUI.Button("Disconnect display and release preview") {
          Task {
            do { try await display.stopSession(); reader.release() }
            catch { library.error = error.localizedDescription }
          }
        }
      } footer: {
        SwiftUI.Text("Only location references are saved. Opened PDFs may be downloaded and cached by Files or Google Drive. Folder access depends on the provider; choose individual PDFs if needed.")
      }.disabled(library.busy || reader.busy || display.isSending)
      Section {
        if library.locations.isEmpty { SwiftUI.Text("Choose PDFs or folders above.").foregroundStyle(.secondary) }
        ForEach(library.locations) { location in
          SwiftUI.Button((location.isFolder ? "Folder: " : "") + location.name) {
            Task {
              await reader.open(HarnessDocument(location: location, path: [], isFolder: location.isFolder), library: library, display: display)
            }
          }.disabled(library.busy || reader.busy || display.isSending)
        }.onDelete(perform: library.forget)
      } header: { SwiftUI.Text("Selected locations") } footer: { SwiftUI.Text("Swipe to forget a location. Its original files are never deleted.") }
      Section("Preview") {
        SwiftUI.Text(reader.status)
        if library.busy || reader.busy || display.isSending { ProgressView("Preparing…") }
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
    .navigationTitle("Harness files")
    .fileImporter(isPresented: $picking, allowedContentTypes: pickingFolders ? [.folder] : [.pdf], allowsMultipleSelection: true) { result in
      switch result {
      case .success(let urls):
        let folders = pickingFolders
        Task { await library.select(urls, folders: folders) }
      case .failure(let error): library.error = error.localizedDescription
      }
    }
    .alert("Files access", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
      SwiftUI.Button("OK") { library.error = nil }
    } message: { SwiftUI.Text(library.error ?? "") }
  }
}
