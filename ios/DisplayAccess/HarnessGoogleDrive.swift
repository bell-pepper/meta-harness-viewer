import Foundation
import Observation
import SwiftUI
import UIKit
@preconcurrency import GoogleSignIn
import GoogleSignInSwift

// All media stays in memory. Refuse redirects so a bearer token cannot be sent
// to a different host; leave system TLS verification enabled.
private final class HarnessDriveTransport: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }

  func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw HarnessDriveError.invalidResponse }
    guard response.expectedContentLength <= limit else { throw HarnessDriveError.tooLarge }
    // Do not retain Google's error bodies (which can include request details).
    guard response.statusCode == 200 else { return (Data(), response) }
    var result = Data()
    for try await byte in bytes {
      if result.count >= limit { throw HarnessDriveError.tooLarge }
      result.append(byte)
    }
    return (result, response)
  }
}

@Observable @MainActor
final class HarnessGoogleDrive {
  static let scope = "https://www.googleapis.com/auth/drive.readonly"
  private(set) var accountID: String?
  private(set) var accountLabel = ""
  private(set) var busy = false
  var error: String?
  private var restored = false
  private var generation = 0
  private let api: HarnessDriveAPI

  init() {
    let transport = HarnessDriveTransport()
    api = HarnessDriveAPI { request, limit in try await transport.fetch(request, limit: limit) }
  }

  var configurationState: HarnessGoogleConfiguration {
    let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
    let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
    let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    return HarnessGoogleConfiguration.inspect(clientID: id, schemes: schemes)
  }

  var isConfigured: Bool { configurationState == .ready }

  private func configure() throws {
    guard isConfigured,
          let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else { throw HarnessDriveError.configure }
    GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: id)
  }

  func restore() async {
    guard !restored, !busy else { return }
    restored = true
    guard isConfigured else { return }
    busy = true
    defer { busy = false }
    do {
      try configure()
      guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
      let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
      try accept(user)
    } catch { self.error = "Your Google connection could not be restored. Sign in again on your phone." }
  }

  func signIn() async {
    guard !busy else { return }
    busy = true
    generation += 1
    accountID = nil
    accountLabel = ""
    error = nil
    defer { busy = false }
    do {
      try configure()
      guard var presenter = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })?
        .windows.first(where: \.isKeyWindow)?.rootViewController else { throw HarnessDriveError.unavailable }
      while let presented = presenter.presentedViewController { presenter = presented }
      let result = try await GIDSignIn.sharedInstance.signIn(
        withPresenting: presenter, hint: nil, additionalScopes: [Self.scope])
      try accept(result.user)
    } catch let error as HarnessDriveError { self.error = error.localizedDescription }
    catch { self.error = "Google sign-in did not complete. Try again and allow read-only Drive access." }
  }

  private func accept(_ user: GIDGoogleUser) throws {
    guard let id = user.userID, user.grantedScopes?.contains(Self.scope) == true else { throw HarnessDriveError.permission }
    generation += 1
    accountID = id
    accountLabel = user.profile?.email ?? "Google Drive"
  }

  func disconnect() async {
    guard !busy else { return }
    busy = true
    generation += 1
    accountID = nil
    accountLabel = ""
    error = nil
    defer { busy = false }
    do { try await GIDSignIn.sharedInstance.disconnect() }
    catch { self.error = "Signed out on this phone. Google could not confirm revocation; remove Harness HUD in your Google Account connections if needed." }
    GIDSignIn.sharedInstance.signOut()
  }

  private func authorized<T: Sendable>(_ account: String, operation: (String) async throws -> T) async throws -> T {
    guard accountID == account else { throw HarnessDriveError.wrongAccount }
    guard let user = GIDSignIn.sharedInstance.currentUser, user.userID == account else { throw HarnessDriveError.signIn }
    let currentGeneration = generation
    let refreshed: GIDGoogleUser
    do { refreshed = try await user.refreshTokensIfNeeded() }
    catch { throw HarnessDriveError.signIn }
    guard accountID == account, generation == currentGeneration, refreshed.userID == account,
          refreshed.grantedScopes?.contains(Self.scope) == true else { throw HarnessDriveError.signIn }
    let result = try await operation(refreshed.accessToken.tokenString)
    guard accountID == account, generation == currentGeneration else { throw HarnessDriveError.wrongAccount }
    return result
  }

  func folder(_ id: String) async throws -> HarnessDriveItem {
    guard let accountID else { throw HarnessDriveError.signIn }
    return try await authorized(accountID) { token in
      let folder = try await self.api.item(id, token: token)
      guard folder.isFolder else { throw HarnessDriveError.notFolder }
      return folder
    }
  }

  func folders(in folder: HarnessDriveItem) async throws -> [HarnessDriveItem] {
    guard let accountID else { throw HarnessDriveError.signIn }
    return try await authorized(accountID) { try await self.api.children(folder.id, token: $0, foldersOnly: true) }
  }

  // Revalidate the saved root and every ancestor before listing/downloading.
  // Folder IDs, rather than expiring URLs or names, survive ordinary renames.
  private func validated(_ document: HarnessDocument, token: String) async throws -> HarnessDriveItem {
    guard let reference = document.location.drive else { throw HarnessDriveError.invalidID }
    return try await api.descendant(root: reference.folderID, path: document.drivePath.map(\.id), token: token)
  }

  func children(of document: HarnessDocument) async throws -> [HarnessDriveItem] {
    guard let reference = document.location.drive else { throw HarnessDriveError.invalidID }
    return try await authorized(reference.accountID) { token in
      let folder = try await self.validated(document, token: token)
      guard folder.isFolder else { throw HarnessDriveError.notFolder }
      return try await self.api.children(folder.id, token: token)
    }
  }

  func pdf(_ document: HarnessDocument) async throws -> Data {
    guard let reference = document.location.drive, let parent = document.parent else { throw HarnessDriveError.invalidID }
    return try await authorized(reference.accountID) { token in
      let folder = try await self.validated(parent, token: token)
      guard let file = document.drivePath.last else { throw HarnessDriveError.notPDF }
      return try await self.api.pdf(file.id, parent: folder.id, token: token)
    }
  }
}

struct HarnessDriveFolderPicker: View {
  var library: HarnessLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var path: [HarnessDriveItem] = []
  @State private var folders: [HarnessDriveItem] = []
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      List {
        if let current = path.last {
          Section {
            SwiftUI.Button("Use folder: \(current.name)") {
              do { try library.selectDriveFolder(current); dismiss() }
              catch { self.error = error.localizedDescription }
            }
            if path.count > 1 {
              SwiftUI.Button("Up one folder") {
                Task { await load(path: Array(path.dropLast())) }
              }
            }
          }
        }
        Section("Folders") {
          if busy { ProgressView("Loading Google Drive…") }
          else if folders.isEmpty { SwiftUI.Text("No subfolders here. You can use the current folder.") }
          ForEach(folders) { folder in
            SwiftUI.Button { Task { await load(path: path + [folder]) } } label: {
              Label(folder.name, systemImage: "folder")
            }
          }
        }
        if let error {
          Section {
            SwiftUI.Text(error).foregroundStyle(.red)
            SwiftUI.Button("Retry") { Task { await load(path: path) } }
          }
        }
      }
      .disabled(busy)
      .harnessSheetStyle()
      .navigationTitle(path.last?.name ?? "Google Drive")
      .toolbar { ToolbarItem(placement: .cancellationAction) { SwiftUI.Button("Cancel") { dismiss() } } }
      .task { await load(path: []) }
    }
  }

  private func load(path requested: [HarnessDriveItem]) async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      let nextPath: [HarnessDriveItem]
      if requested.isEmpty { nextPath = [try await library.drive.folder("root")] }
      else { nextPath = requested }
      guard let current = nextPath.last else { return }
      let entries = try await library.drive.folders(in: current)
      try Task.checkCancellation()
      path = nextPath
      folders = entries
    } catch is CancellationError { }
    catch { self.error = error.localizedDescription }
  }
}

struct HarnessGoogleDriveSettingsView: View {
  var library: HarnessLibrary
  var reader: HarnessReader
  var display: DisplayViewModel
  @State private var choosingFolder = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        accountSection
      }
      .harnessSheetStyle()
      .navigationTitle("Google Drive")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { SwiftUI.Button("Done") { dismiss() } } }
    }
    .preferredColorScheme(.dark)
  }

  private var accountSection: some View {
    Section {
      if let _ = library.drive.accountID {
        SwiftUI.Text(library.drive.accountLabel)
        SwiftUI.Button("Choose a Google Drive folder") { choosingFolder = true }
        SwiftUI.Button("Reconnect / switch Google account") {
          Task {
            do { try await display.stopSession() }
            catch { library.error = "Could not stop the display. Try reconnecting again."; return }
            reader.release()
            await library.drive.signIn()
          }
        }
        SwiftUI.Button("Disconnect Google Drive", role: .destructive) {
          Task {
            // Clear the page on the glasses before dropping its authorization.
            do { try await display.stopSession() }
            catch { library.error = "Could not stop the display. Try disconnecting again."; return }
            reader.release()
            await library.drive.disconnect()
          }
        }
      } else if library.drive.isConfigured {
        GoogleSignInButton(scheme: .light, style: .wide) { Task { await library.drive.signIn() } }
      } else {
        Label("Google setup required", systemImage: "exclamationmark.circle")
          .font(.headline).foregroundStyle(.orange)
        SwiftUI.Text(library.drive.configurationState.message ?? "Configure Google sign-in for this build.")
        DisclosureGroup("One-time setup on your Mac") {
          VStack(alignment: .leading, spacing: 14) {
            SwiftUI.Text("1. Enable Google Drive API and configure the OAuth consent screen in Google Cloud. Add your account as a test user if the app is in testing.")
            SwiftUI.Text("2. Create an iOS OAuth client for this app's bundle identifier:")
            SwiftUI.Text(Bundle.main.bundleIdentifier ?? "Check Signing & Capabilities in Xcode")
              .font(.callout.monospaced()).textSelection(.enabled)
            SwiftUI.Text("3. Copy ios/GoogleDrive.local.xcconfig.example to ios/GoogleDrive.local.xcconfig on your Mac. Set the iOS client ID and its reversed client ID. No client secret is needed.")
            if case .missingCallback(let scheme) = library.drive.configurationState {
              SwiftUI.Text("Expected callback scheme:")
              SwiftUI.Text(scheme).font(.callout.monospaced()).textSelection(.enabled)
            }
            SwiftUI.Text("4. Rebuild and run on this iPhone. The Sign in with Google button will then appear here. Saved folders stay available after reconnecting the same account.")
            Link("Open Google Cloud credentials", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
          }
          .font(.subheadline).padding(.vertical, 8)
        }
      }
      if library.drive.busy { ProgressView("Connecting…") }
      if let error = library.drive.error { SwiftUI.Text(error).foregroundStyle(.red) }
    } header: { SwiftUI.Text("Google Drive") } footer: {
      SwiftUI.Text("Connect Google, then select folders once. Read-only access covers your Drive account; only selected folders appear on the glasses. PDFs download to phone memory while reading.")
    }
    .disabled(library.drive.busy || library.busy || reader.busy || display.isSending)
    .sheet(isPresented: $choosingFolder) { HarnessDriveFolderPicker(library: library) }
  }
}
