import SwiftUI
import UniformTypeIdentifiers

enum HarnessTheme {
  static let background = Color(red: 0.03, green: 0.06, blue: 0.09)
  static let surface = Color(red: 0.06, green: 0.10, blue: 0.14)
  static let border = Color(red: 0.15, green: 0.20, blue: 0.25)
  static let mint = Color(red: 0.46, green: 0.95, blue: 0.80)
  static let secondary = Color(red: 0.61, green: 0.67, blue: 0.73)
}

extension View {
  func harnessCard(padding: CGFloat = 18) -> some View {
    self.padding(padding)
      .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(HarnessTheme.border, lineWidth: 1)
      }
  }

  func harnessSheetStyle() -> some View {
    self.scrollContentBackground(.hidden)
      .background(HarnessTheme.background)
      .tint(HarnessTheme.mint)
  }
}

private struct HarnessPressStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
  }
}

struct HarnessLibraryView: View {
  var display: DisplayViewModel
  var library: HarnessLibrary
  var reader: HarnessReader
  var glassesAvailable: Bool
  var openSettings: () -> Void
  @State private var picking = false
  @State private var pickingFolders = false
  @State private var managingDrive = false
  @State private var choosingDriveFolder = false
  @State private var managingConnection = false
  @State private var showingReader = false
  @State private var editingLocations = false

  private var working: Bool { library.busy || library.drive.busy || reader.busy || display.isSending }
  private var viewingOnGlasses: Bool { glassesAvailable && display.isConnected && display.errorMessage == nil }

  private var connectionTitle: String {
    if display.errorMessage != nil || display.inputProblem != nil { return "Connection needs attention" }
    if display.isSending { return "Preparing display…" }
    if viewingOnGlasses { return "Glasses connected" }
    return glassesAvailable ? "Glasses ready" : "Connect your glasses"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        brand
        connectionCard
        libraryHeading
        driveCard
        savedLocations
        if reader.busy || library.busy {
          HStack(spacing: 12) {
            ProgressView().tint(HarnessTheme.mint)
            Text(reader.busy ? reader.status : "Saving your locations…")
              .font(.subheadline).foregroundStyle(HarnessTheme.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .harnessCard()
          .accessibilityElement(children: .combine)
        }
        if let message = reader.failure ?? display.errorMessage ?? display.inputProblem ?? library.drive.error {
          Label(message, systemImage: "exclamationmark.circle")
            .font(.subheadline).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading).harnessCard()
        }
        if let image = reader.image, let name = reader.documentName {
          Button { showingReader = true } label: {
            VStack(alignment: .leading, spacing: 16) {
              HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("Reading now").font(.title3.weight(.semibold))
                  Text(name).font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineLimit(2)
                }
                Spacer(minLength: 12)
                Image(systemName: "doc.text").font(.title2).foregroundStyle(HarnessTheme.secondary)
              }
              HStack(spacing: 16) {
                Image(uiImage: image).resizable().scaledToFit()
                  .frame(width: 120, height: 100).background(.black)
                  .clipShape(RoundedRectangle(cornerRadius: 8))
                  .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                  Text(reader.pageLabel).font(.headline)
                  Text(display.isSending ? "Sending to glasses…" : viewingOnGlasses ? "Viewing on glasses" : "Phone preview")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HarnessTheme.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading).harnessCard()
          }
          .buttonStyle(HarnessPressStyle())
          .accessibilityHint("Opens the current page preview and phone controls")
        }
        addFromFiles
        Text("Select folders once. Browse on your glasses.")
          .font(.footnote).foregroundStyle(HarnessTheme.secondary)
          .frame(maxWidth: .infinity).multilineTextAlignment(.center)
      }
      .padding(.horizontal, 22).padding(.vertical, 20)
      .frame(maxWidth: 640).frame(maxWidth: .infinity)
    }
    .background(HarnessTheme.background)
    .foregroundStyle(.white)
    .toolbar(.hidden, for: .navigationBar)
    .sheet(isPresented: $managingDrive) {
      HarnessGoogleDriveSettingsView(library: library, reader: reader, display: display)
    }
    .sheet(isPresented: $choosingDriveFolder) {
      HarnessDriveFolderPicker(library: library).preferredColorScheme(.dark)
    }
    .sheet(isPresented: $managingConnection) { connectionSheet }
    .sheet(isPresented: $showingReader) { readerSheet }
    .onChange(of: library.availableLocations.map(\.id)) { _, _ in
      guard display.isConnected else { return }
      Task { await reader.presentLibrary(library, display: display) }
    }
    .fileImporter(isPresented: $picking, allowedContentTypes: pickingFolders ? [.folder] : [.pdf], allowsMultipleSelection: true) { result in
      switch result {
      case .success(let urls):
        let folders = pickingFolders
        Task { await library.select(urls, folders: folders) }
      case .failure(let error): library.error = error.localizedDescription
      }
    }
    .alert("Library", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
      Button("OK") { library.error = nil }
    } message: { Text(library.error ?? "") }
  }

  private var brand: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "scope").font(.system(size: 36, weight: .light))
        .foregroundStyle(HarnessTheme.mint).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Harness HUD").font(.largeTitle.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
          .accessibilityAddTraits(.isHeader)
        Text("Your documents. In view.").font(.subheadline).foregroundStyle(HarnessTheme.secondary)
      }
    }
    .padding(.bottom, 4)
  }

  private var connectionCard: some View {
    Button { managingConnection = true } label: {
      HStack(spacing: 16) {
        Image(systemName: "eyeglasses").font(.system(size: 32)).foregroundStyle(HarnessTheme.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 8) {
            Text(connectionTitle).font(.headline)
            Circle().fill(display.errorMessage != nil || display.inputProblem != nil ? Color.orange : viewingOnGlasses ? HarnessTheme.mint : HarnessTheme.secondary)
              .frame(width: 7, height: 7).accessibilityHidden(true)
          }
          Text(display.inputProblem != nil ? "Check gesture setup" : viewingOnGlasses && display.gesturesActive ? "Ready to read" : glassesAvailable ? "Open your library to begin" : "Pair in Settings to start reading")
            .font(.subheadline).foregroundStyle(HarnessTheme.secondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HarnessTheme.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).harnessCard()
    }
    .buttonStyle(HarnessPressStyle())
    .accessibilityHint("Opens display connection actions")
  }

  private var libraryHeading: some View {
    HStack {
      Text("Library").font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
      Spacer()
      Menu {
        Button(library.drive.accountID == nil ? "Connect Google Drive" : "Google Drive folder", systemImage: "cloud") {
          if library.drive.accountID == nil { managingDrive = true }
          else { choosingDriveFolder = true }
        }
        Button("PDFs from Files", systemImage: "doc.badge.plus") { pickFiles(folder: false) }
        Button("Folder from Files", systemImage: "folder.badge.plus") { pickFiles(folder: true) }
      } label: {
        Image(systemName: "plus.circle").font(.system(size: 29, weight: .light))
          .foregroundStyle(HarnessTheme.mint).frame(minWidth: 44, minHeight: 44)
      }
      .disabled(working).accessibilityLabel("Add a library location")
    }
  }

  private var driveCard: some View {
    Button { managingDrive = true } label: {
      HStack(spacing: 16) {
        HarnessDriveMark().frame(width: 36, height: 36).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Google Drive").font(.headline)
          Text(library.drive.busy ? "Connecting…" : library.drive.accountID != nil ? "Connected" : library.drive.isConfigured ? "Connect your account" : "Setup required")
            .font(.subheadline).foregroundStyle(HarnessTheme.secondary)
        }
        Spacer(minLength: 4)
        Text(library.drive.accountID != nil ? "Manage" : library.drive.isConfigured ? "Connect" : "Details")
          .font(.subheadline).foregroundStyle(HarnessTheme.mint)
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HarnessTheme.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).harnessCard()
    }
    .buttonStyle(HarnessPressStyle())
    .accessibilityHint("Opens Google account and folder management")
  }

  private var savedLocations: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("SAVED LOCATIONS").font(.caption.weight(.medium)).tracking(1)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 4)
        if !library.availableLocations.isEmpty {
          Text("\(library.availableLocations.count) saved").font(.caption)
          Button(editingLocations ? "Done" : "Edit") { editingLocations.toggle() }
            .font(.subheadline).foregroundStyle(HarnessTheme.mint).frame(minHeight: 44)
            .disabled(working).accessibilityLabel(editingLocations ? "Finish editing locations" : "Edit saved locations")
        }
      }
      .foregroundStyle(HarnessTheme.secondary)
      if library.availableLocations.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(HarnessTheme.mint)
            .accessibilityHidden(true)
          Text("Your library starts here").font(.headline)
          Text("Connect Google Drive or add a PDF from Files.")
            .font(.subheadline).foregroundStyle(HarnessTheme.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12).harnessCard()
      } else {
        VStack(spacing: 0) {
          ForEach(library.availableLocations) { location in
            if location.id != library.availableLocations.first?.id {
              Rectangle().fill(HarnessTheme.border).frame(height: 1).padding(.leading, 72)
            }
            HStack(spacing: 0) {
              Button {
                Task { await reader.open(HarnessDocument(location: location, path: [], isFolder: location.isFolder), library: library, display: display) }
              } label: {
                HStack(spacing: 16) {
                  Image(systemName: location.isFolder ? "folder.fill" : "doc.text")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(location.drive != nil ? HarnessTheme.mint : HarnessTheme.secondary)
                    .frame(width: 36).accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(location.name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    Text(location.drive != nil ? "Google Drive" : "Files")
                      .font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                  }
                  Spacer(minLength: 8)
                  if !editingLocations {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HarnessTheme.secondary)
                  }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(18).contentShape(Rectangle())
              }
              .buttonStyle(HarnessPressStyle())
              .accessibilityHint(location.isFolder ? "Opens this folder on glasses" : "Opens this PDF on glasses")
              .contextMenu {
                Button("Forget location", systemImage: "minus.circle", role: .destructive) { library.forget(id: location.id) }
              }
              if editingLocations {
                Button(role: .destructive) { library.forget(id: location.id) } label: {
                  Image(systemName: "minus.circle.fill").font(.title3).frame(minWidth: 44, minHeight: 44)
                }
                .padding(.trailing, 8).accessibilityLabel("Forget \(location.name)")
              }
            }
          }
        }
        .harnessCard(padding: 0).disabled(working)
      }
    }
  }

  private var addFromFiles: some View {
    Menu {
      Button("Choose PDFs", systemImage: "doc.badge.plus") { pickFiles(folder: false) }
      Button("Choose a folder", systemImage: "folder.badge.plus") { pickFiles(folder: true) }
    } label: {
      Label("Add from Files", systemImage: "folder.badge.plus")
        .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
        .background(HarnessTheme.background, in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(HarnessTheme.secondary.opacity(0.7), lineWidth: 1) }
    }
    .disabled(working)
  }

  private func pickFiles(folder: Bool) {
    pickingFolders = folder
    picking = true
  }

  private var connectionSheet: some View {
    NavigationStack {
      List {
        Section {
          Label(connectionTitle, systemImage: "eyeglasses")
          Button("Open library on glasses") {
            Task {
              if display.errorMessage != nil || display.inputProblem != nil {
                do { try await display.stopSession(); reader.release() }
                catch { library.error = error.localizedDescription; return }
              }
              await reader.presentLibrary(library, display: display)
            }
          }
            .disabled(working || library.availableLocations.isEmpty)
          Button("Disconnect display", role: .destructive) {
            Task {
              do { try await display.stopSession(); reader.release() }
              catch { library.error = error.localizedDescription }
            }
          }
          .disabled(reader.busy || library.busy || library.drive.busy)
          Button("Connection settings") { managingConnection = false; openSettings() }
        }
        Section("Gesture input") {
          Text(display.inputStatus).font(.subheadline)
          Button("Restart gesture input") { display.restartGestureInput() }
            .disabled(working || !display.isConnected)
          if display.recentInputs.isEmpty {
            Text("No gesture events received yet.").font(.caption).foregroundStyle(HarnessTheme.secondary)
          } else {
            ForEach(Array(display.recentInputs.enumerated()), id: \.offset) { _, event in
              Text(event).font(.caption).foregroundStyle(HarnessTheme.secondary)
            }
          }
          Text("Meta SDK 1.0.x does not deliver the middle-finger Back gesture on real glasses. It closes the glasses app even with consumeBack enabled. Restarting gesture input cannot change that system behaviour.")
            .font(.caption).foregroundStyle(HarnessTheme.secondary)
          Text("Select cycles fit, 2× and 3×. At fit: Left/Right changes pages; Up returns to documents. At zoom: directions pan. In folder lists: Up/Down browses; Left goes up; Select opens. The middle-finger Back gesture still exits.")
            .font(.subheadline).foregroundStyle(HarnessTheme.secondary)
        }
      }
      .harnessSheetStyle().navigationTitle("Glasses").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { managingConnection = false } } }
    }
    .preferredColorScheme(.dark)
  }

  private var readerSheet: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(reader.documentName ?? "No document open").font(.title2.weight(.semibold))
          if let image = reader.image {
            Image(uiImage: image).resizable().scaledToFit().background(.black)
              .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel("Current PDF page")
            Text(reader.pageLabel).font(.headline)
            HStack {
              Button("Previous", systemImage: "chevron.left") { Task { await reader.turn(-1, display: display) } }
                .disabled(working || !reader.canGoBack)
              Spacer()
              Button("Next", systemImage: "chevron.right") { Task { await reader.turn(1, display: display) } }
                .disabled(working || !reader.canGoForward)
            }
            .buttonStyle(.bordered).controlSize(.large)
            Button("Show on glasses", systemImage: "eyeglasses") { Task { await reader.show(display) } }
              .buttonStyle(.borderedProminent).foregroundStyle(HarnessTheme.background).disabled(working)
          }
          if reader.busy || display.isSending { ProgressView("Preparing page…") }
          if let failure = reader.failure ?? display.errorMessage { Text(failure).foregroundStyle(.orange) }
        }
        .padding(22).frame(maxWidth: 640).frame(maxWidth: .infinity)
      }
      .harnessSheetStyle().navigationTitle("Reading now").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingReader = false } } }
    }
    .preferredColorScheme(.dark)
  }
}

// A small vector mark keeps the provider recognizable without a remote image
// dependency. Authentication uses Google's official sign-in button in Manage.
private struct HarnessDriveMark: View {
  var body: some View {
    GeometryReader { geometry in
      let w = geometry.size.width
      let h = geometry.size.height
      ZStack {
        Path { path in
          path.move(to: CGPoint(x: 0.38 * w, y: 0.08 * h))
          path.addLines([CGPoint(x: 0.62 * w, y: 0.08 * h), CGPoint(x: 0.27 * w, y: 0.70 * h), CGPoint(x: 0.02 * w, y: 0.70 * h)])
          path.closeSubpath()
        }.fill(Color(red: 0.06, green: 0.62, blue: 0.35))
        Path { path in
          path.move(to: CGPoint(x: 0.62 * w, y: 0.08 * h))
          path.addLines([CGPoint(x: 0.98 * w, y: 0.70 * h), CGPoint(x: 0.73 * w, y: 0.70 * h), CGPoint(x: 0.50 * w, y: 0.30 * h)])
          path.closeSubpath()
        }.fill(Color(red: 0.98, green: 0.74, blue: 0.02))
        Path { path in
          path.move(to: CGPoint(x: 0.02 * w, y: 0.70 * h))
          path.addLines([CGPoint(x: 0.98 * w, y: 0.70 * h), CGPoint(x: 0.85 * w, y: 0.92 * h), CGPoint(x: 0.15 * w, y: 0.92 * h)])
          path.closeSubpath()
        }.fill(Color(red: 0.26, green: 0.52, blue: 0.96))
      }
    }
  }
}
