import SwiftUI
import PDFKit
import UIKit
import CoreImage
import UniformTypeIdentifiers
import Observation
import MWDATDisplay
import MWDATInputs

private enum HarnessError: LocalizedError {
  case invalidPDF, unavailable, invalidFolder, changedDocument
  var errorDescription: String? {
    switch self {
    case .invalidPDF: "Choose an unlocked PDF containing 1–1000 pages."
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
    guard document.location.drive == nil else { throw HarnessError.unavailable }
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
    return HarnessLocation(id: UUID(), name: source.lastPathComponent, bookmark: bookmark, isFolder: folder, drive: nil)
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
  let drive = HarnessGoogleDrive()
  var availableLocations: [HarnessLocation] {
    locations.filter { $0.drive == nil || $0.drive?.accountID == drive.accountID }
  }
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
      let visible = availableLocations
      let ids = Set(offsets.compactMap { visible.indices.contains($0) ? visible[$0].id : nil })
      try save(locations.filter { !ids.contains($0.id) })
    } catch { self.error = error.localizedDescription }
    // Forgetting a reference never deletes a file or folder in Drive/Files.
  }

  func forget(id: UUID) {
    do { try save(locations.filter { $0.id != id }) }
    catch { self.error = error.localizedDescription }
  }

  func selectDriveFolder(_ folder: HarnessDriveItem) throws {
    guard folder.isFolder, let account = drive.accountID else { throw HarnessDriveError.signIn }
    try HarnessDriveAPI.validateID(folder.id)
    let existing = locations.first { $0.drive?.accountID == account && $0.drive?.folderID == folder.id }
    let location = HarnessLocation(id: existing?.id ?? UUID(), name: folder.name, bookmark: Data(), isFolder: true,
      drive: HarnessDriveLocation(accountID: account, folderID: folder.id))
    try save(locations.filter { $0.id != location.id } + [location])
  }

  func pdfSource(for document: HarnessDocument) async throws -> HarnessPDFSource {
    if document.location.drive != nil { return .drive(try await drive.pdf(document)) }
    return .files(document)
  }

  func entries(in folder: HarnessDocument?) async throws -> [HarnessDocument] {
    guard let folder else {
      return availableLocations.map { HarnessDocument(location: $0, path: [], isFolder: $0.isFolder) }
    }
    guard folder.isFolder else { throw HarnessError.invalidFolder }
    if folder.location.drive != nil {
      return try await drive.children(of: folder).map {
        HarnessDocument(location: folder.location, path: [], isFolder: $0.isFolder, drivePath: folder.drivePath + [$0])
      }
    }
    return try await Task.detached(priority: .userInitiated) { try HarnessFiles.children(of: folder) }.value
  }
}

enum HarnessPDFSource: Sendable {
  case files(HarnessDocument)
  case drive(Data)
}

// Only the current Drive PDF is held in memory. Local PDFs retain their existing
// Files-provider access. PDFKit objects never cross the worker boundary.
private enum HarnessPDFRenderer {
  private static func withPDF<T>(_ source: HarnessPDFSource, operation: (PDFDocument) throws -> T) throws -> T {
    func read(_ pdf: PDFDocument?) throws -> T {
      guard let pdf, !pdf.isLocked, (1...1000).contains(pdf.pageCount) else { throw HarnessError.invalidPDF }
      return try operation(pdf)
    }
    switch source {
    case .files(let document):
      return try HarnessFiles.coordinate(document) { try read(PDFDocument(url: $0)) }
    case .drive(let data):
      return try read(PDFDocument(data: data))
    }
  }

  static func count(_ source: HarnessPDFSource) throws -> Int {
    try withPDF(source) { $0.pageCount }
  }

  static func render(_ source: HarnessPDFSource, page index: Int, zoom: CGFloat, pan: CGPoint) throws -> Data {
    try withPDF(source) { pdf in
      guard let page = pdf.page(at: index) else { throw HarnessError.changedDocument }
      let canvas = CGSize(width: 600, height: 600)
      let bounds = page.bounds(for: .cropBox)
      let rotation = ((page.rotation % 360) + 360) % 360
      let size = rotation == 90 || rotation == 270
        ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
      guard size.width > 0, size.height > 0 else { throw HarnessError.invalidPDF }
      let scale = min(canvas.width / size.width, canvas.height / size.height) * zoom
      let drawingSize = CGSize(width: size.width * scale, height: size.height * scale)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      let raster = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: canvas))
        var origin = CGPoint(x: (canvas.width - drawingSize.width) / 2, y: (canvas.height - drawingSize.height) / 2)
        origin.x += max(-1, min(1, pan.x)) * max(0, drawingSize.width - canvas.width) / 2
        origin.y += max(-1, min(1, pan.y)) * max(0, drawingSize.height - canvas.height) / 2
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
  private(set) var failure: String?
  var documentName: String? {
    guard let selected else { return nil }
    return selected.drivePath.last?.name ?? selected.path.last ?? selected.location.name
  }
  var pageLabel: String { "Page \(page + 1) of \(pages)" }
  var canGoBack: Bool { selected != nil && page > 0 }
  var canGoForward: Bool { selected != nil && page + 1 < pages }
  private var selected: HarnessDocument?
  private var source: HarnessPDFSource?
  private var folder: HarnessDocument?
  private var menuEntries: [HarnessDocument] = []
  private var focusedIndex = 0
  private var library: HarnessLibrary?
  private var page = 0
  private var pages = 0
  private var zoom: CGFloat = 1
  private var pan = CGPoint.zero

  func open(_ document: HarnessDocument, library: HarnessLibrary, display: DisplayViewModel) async {
    guard !busy, !display.isSending else { return }
    if document.isFolder { await menu(library, display: display, folder: document); return }
    self.library = library
    display.onHarnessInput = { [weak self, weak display] event in
      guard let self, let display else { return }
      await self.handle(event, display: display)
    }
    self.folder = document.parent
    failure = nil
    selected = nil
    source = nil
    image = nil
    busy = true
    status = "Opening \(document.title)… Drive may need to download it."
    do {
      let source = try await library.pdfSource(for: document)
      let count = try await Task.detached(priority: .userInitiated) { try HarnessPDFRenderer.count(source) }.value
      self.source = source
      selected = document
      page = 0
      pages = count
      zoom = 1
      pan = .zero
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
    display.onHarnessInput = { [weak self, weak display] event in
      guard let self, let display else { return }
      await self.handle(event, display: display)
    }
    busy = true
    defer { busy = false }
    image = nil
    source = nil
    failure = nil
    do {
      let entries = try await library.entries(in: folder)
      self.folder = folder
      selected = nil
      menuEntries = entries
      focusedIndex = min(max(index, 0), max(entries.count - 1, 0))
      status = folder?.title ?? "Selected locations"
      await sendMenu(display)
    } catch { await showFailure(error, library: library, display: display) }
  }

  private func sendMenu(_ display: DisplayViewModel) async {
    let entries = menuEntries
    let start = (focusedIndex / 3) * 3
    await display.send(
      FlexBox(direction: .column, spacing: 8) {
        MWDATDisplay.Text(folder?.title ?? "Harness files", style: .heading)
        if entries.isEmpty {
          MWDATDisplay.Text(folder == nil ? "Choose PDFs or a folder on your iPhone first." : "No PDF files or subfolders here.", style: .body)
        } else {
          MWDATDisplay.Text("\(start + 1)–\(min(start + 3, entries.count)) of \(entries.count)", style: .body)
          for offset in start..<min(start + 3, entries.count) {
            let entry = entries[offset]
            MWDATDisplay.Text(
              String(((offset == focusedIndex ? "> " : "  ")
                + (entry.location.drive != nil && entry.drivePath.isEmpty ? "Drive: " : entry.isFolder ? "Folder: " : "")
                + entry.title).prefix(44)), style: .body)
          }
        }
        MWDATDisplay.Text("Navigate to browse · Select to open · Back to go up", style: .body)
      }.padding(16)
    )
  }

  private func showFailure(_ error: Error, library: HarnessLibrary, display: DisplayViewModel) async {
    status = error.localizedDescription
    failure = error.localizedDescription
    selected = nil
    source = nil
    image = nil
    folder = nil
    menuEntries = []
    await display.send(
      FlexBox(direction: .column, spacing: 12) {
        MWDATDisplay.Text("Could not open location", style: .heading)
        MWDATDisplay.Text(String(error.localizedDescription.prefix(220)), style: .body)
        MWDATDisplay.Text("Back to return to saved locations", style: .body)
      }.padding(16)
    )
  }

  func show(_ display: DisplayViewModel) async {
    guard let selected, let source, !busy, !display.isSending else { return }
    busy = true
    defer { busy = false }
    let index = page, magnification = zoom, offset = pan
    do {
      let data = try await Task.detached(priority: .userInitiated) {
        try HarnessPDFRenderer.render(source, page: index, zoom: magnification, pan: offset)
      }.value
      guard let rendered = UIImage(data: data) else { throw HarnessError.invalidPDF }
      image = rendered
      status = "\(selected.title) · \(page + 1)/\(pages)" + (zoom > 1 ? " · \(Int(zoom))×" : "")
      // Reading view sends only a page image; Inputs handles gestures.
      await display.send(
        FlexBox(direction: .column) {
          MWDATDisplay.Image(image: rendered, sizePreset: .fill)
        }.padding(0)
      )
    } catch {
      if let library { await showFailure(error, library: library, display: display) }
      else { status = error.localizedDescription }
    }
  }

  func handle(_ event: InputEvent, display: DisplayViewModel) async {
    guard !busy, !display.isSending, let library else { return }
    switch event {
    case .nav(let direction, _, _):
      if selected == nil {
        let delta = (direction == .up || direction == .left) ? -1 : 1
        let next = min(max(focusedIndex + delta, 0), max(menuEntries.count - 1, 0))
        if next != focusedIndex {
          focusedIndex = next
          await sendMenu(display)
        }
      } else if zoom == 1 {
        if direction == .left { await turn(-1, display: display) }
        if direction == .right { await turn(1, display: display) }
      } else {
        switch direction {
        case .left: await move(1, 0, display: display)
        case .right: await move(-1, 0, display: display)
        case .up: await move(0, 1, display: display)
        case .down: await move(0, -1, display: display)
        }
      }
    case .select:
      if selected != nil {
        zoom = zoom == 3 ? 1 : zoom + 1
        pan = .zero
        await show(display)
      } else if menuEntries.indices.contains(focusedIndex) {
        await open(menuEntries[focusedIndex], library: library, display: display)
      }
    case .back:
      if selected != nil, zoom > 1 {
        zoom = 1
        pan = .zero
        await show(display)
      } else if selected != nil {
        await menu(library, display: display, folder: folder, index: focusedIndex)
      } else {
        await menu(library, display: display, folder: folder?.parent)
      }
    case .drag(let action, _, _, let dx, let dy, _, _):
      guard selected != nil, zoom > 1, action == .move,
            dx.isFinite, dy.isFinite else { return }
      // Delta sensitivity and orientation need verification on real hardware.
      pan.x = max(-1, min(1, pan.x + CGFloat(dx)))
      pan.y = max(-1, min(1, pan.y + CGFloat(dy)))
      await show(display)
    case .button, .capture:
      break
    @unknown default:
      break
    }
  }

  func turn(_ delta: Int, display: DisplayViewModel) async {
    guard !busy, !display.isSending else { return }
    page = min(max(page + delta, 0), max(pages - 1, 0))
    zoom = 1
    pan = .zero
    await show(display)
  }

  func move(_ x: CGFloat, _ y: CGFloat, display: DisplayViewModel) async {
    guard selected != nil, zoom > 1, !busy, !display.isSending else { return }
    pan.x = max(-1, min(1, pan.x + x * 0.5))
    pan.y = max(-1, min(1, pan.y + y * 0.5))
    await show(display)
  }

  func release() {
    image = nil
    selected = nil
    source = nil
    failure = nil
    menuEntries = []
    folder = nil
    status = "Page preview released. Files/Drive may keep its own cached download."
  }
}
