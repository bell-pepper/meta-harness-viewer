import Foundation

@MainActor
final class HarnessLibraryPreferences {
  private let defaults: UserDefaults
  private let key = "HarnessLastFolderID"

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func remember(_ location: HarnessLocation) {
    guard location.isFolder else { return }
    defaults.set(location.id.uuidString, forKey: key)
  }

  func forget(_ id: UUID) {
    if defaults.string(forKey: key) == id.uuidString { defaults.removeObject(forKey: key) }
  }

  func preferredFolder(in available: [HarnessLocation]) -> HarnessDocument? {
    let remembered = available.first { $0.id.uuidString == defaults.string(forKey: key) && $0.isFolder }
    // A single saved folder also restores references from older app builds.
    let location = remembered ?? (available.count == 1 && available[0].isFolder ? available[0] : nil)
    return location.map { HarnessDocument(location: $0, path: [], isFolder: true) }
  }
}

enum HarnessGoogleConfiguration: Equatable {
  case ready
  case missingClientID
  case invalidClientID
  case missingCallback(String)

  static func inspect(clientID: String?, schemes: [String]) -> Self {
    guard let clientID, !clientID.isEmpty, !clientID.contains("$(") else { return .missingClientID }
    let suffix = ".apps.googleusercontent.com"
    guard clientID.hasSuffix(suffix) else { return .invalidClientID }
    let prefix = String(clientID.dropLast(suffix.count))
    guard !prefix.isEmpty,
          !prefix.localizedCaseInsensitiveContains("YOUR"),
          prefix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
      return .invalidClientID
    }
    let reversed = "com.googleusercontent.apps." + prefix
    return schemes.contains(reversed) ? .ready : .missingCallback(reversed)
  }

  var message: String? {
    switch self {
    case .ready: nil
    case .missingClientID: "This build has no Google iOS client ID. Google sign-in needs to be configured once before it can connect."
    case .invalidClientID: "The Google iOS client ID in this build is incomplete or invalid. Replace the example value with your actual iOS OAuth client ID."
    case .missingCallback: "The Google callback URL scheme does not match the iOS client ID. Update the reversed client ID and rebuild."
    }
  }
}
