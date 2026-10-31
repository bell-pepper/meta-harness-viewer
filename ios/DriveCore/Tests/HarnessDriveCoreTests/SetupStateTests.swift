import Foundation
import Testing
@testable import HarnessDriveCore

@Test @MainActor func rememberedFolderSurvivesANewPreferencesInstance() {
  let suite = "HarnessTests-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let first = HarnessLocation(id: UUID(), name: "First", bookmark: Data(), isFolder: true, drive: nil)
  let last = HarnessLocation(id: UUID(), name: "Last", bookmark: Data(), isFolder: true, drive: nil)
  HarnessLibraryPreferences(defaults: defaults).remember(last)
  let restored = HarnessLibraryPreferences(defaults: defaults)
  #expect(restored.preferredFolder(in: [first, last])?.location.id == last.id)
  restored.forget(last.id)
  #expect(restored.preferredFolder(in: [first, last]) == nil)
}

@Test @MainActor func missingOrOtherAccountLocationsCannotBeRestored() {
  let suite = "HarnessTests-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let drive = HarnessLocation(id: UUID(), name: "Private", bookmark: Data(), isFolder: true,
    drive: HarnessDriveLocation(accountID: "other-account", folderID: "folder"))
  let preferences = HarnessLibraryPreferences(defaults: defaults)
  preferences.remember(drive)
  #expect(preferences.preferredFolder(in: []) == nil)
  let pdf = HarnessLocation(id: UUID(), name: "Local.pdf", bookmark: Data(), isFolder: false, drive: nil)
  #expect(preferences.preferredFolder(in: [pdf]) == nil)
}

@Test @MainActor func oneOldSavedFolderRestoresWithoutASelectionPreference() {
  let suite = "HarnessTests-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let folder = HarnessLocation(id: UUID(), name: "Saved folder", bookmark: Data([1]), isFolder: true, drive: nil)
  #expect(HarnessLibraryPreferences(defaults: defaults).preferredFolder(in: [folder])?.location.id == folder.id)
}

@Test func googleConfigurationSeparatesMissingInvalidAndMismatchedSettings() {
  #expect(HarnessGoogleConfiguration.inspect(clientID: nil, schemes: []) == .missingClientID)
  #expect(HarnessGoogleConfiguration.inspect(clientID: "$(GOOGLE_IOS_CLIENT_ID)", schemes: []) == .missingClientID)
  #expect(HarnessGoogleConfiguration.inspect(clientID: "YOUR_IOS_CLIENT_ID.apps.googleusercontent.com", schemes: []) == .invalidClientID)
  #expect(HarnessGoogleConfiguration.inspect(clientID: "client.apps.googleusercontent.com ", schemes: []) == .invalidClientID)
  #expect(HarnessGoogleConfiguration.inspect(clientID: "123-abc.apps.googleusercontent.com", schemes: ["harnesshud"]) == .missingCallback("com.googleusercontent.apps.123-abc"))
  #expect(HarnessGoogleConfiguration.inspect(clientID: "123-abc.apps.googleusercontent.com", schemes: ["harnesshud", "com.googleusercontent.apps.123-abc"]) == .ready)
}
