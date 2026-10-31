import Foundation
import Testing
@testable import HarnessDriveCore

@Test func oldFilesBookmarksRemainReadableWithoutDriveFields() throws {
  let original = #"[{"id":"01234567-89AB-CDEF-0123-456789ABCDEF","name":"Local drawings","bookmark":"AQID","isFolder":true}]"#
  let locations = try JSONDecoder().decode([HarnessLocation].self, from: Data(original.utf8))
  #expect(locations.count == 1)
  #expect(locations[0].bookmark == Data([1, 2, 3]))
  #expect(locations[0].drive == nil)
  #expect(locations[0].isFolder)
}

@Test func driveReferenceRoundTripsWithStableAccountAndFolderIDs() throws {
  let reference = HarnessLocation(id: UUID(), name: "Engineering", bookmark: Data(), isFolder: true,
    drive: HarnessDriveLocation(accountID: "account-a", folderID: "folder_1"))
  let decoded = try JSONDecoder().decode(HarnessLocation.self, from: JSONEncoder().encode(reference))
  #expect(decoded.id == reference.id)
  #expect(decoded.drive?.accountID == "account-a")
  #expect(decoded.drive?.folderID == "folder_1")
  #expect(decoded.bookmark.isEmpty)
}

@Test func driveParentNavigationUsesIDsInsteadOfNamesOrFilesystemPaths() {
  let location = HarnessLocation(id: UUID(), name: "Engineering", bookmark: Data(), isFolder: true,
    drive: HarnessDriveLocation(accountID: "account-a", folderID: "root-folder"))
  let subfolder = HarnessDriveItem(id: "folder_2", name: "Sub/folder", mimeType: HarnessDriveItem.folderType)
  let pdf = HarnessDriveItem(id: "pdf_1", name: "Drawing.pdf", mimeType: HarnessDriveItem.pdfType)
  let document = HarnessDocument(location: location, path: [], isFolder: false, drivePath: [subfolder, pdf])
  #expect(document.title == "Drawing")
  #expect(document.id.hasSuffix("/folder_2/pdf_1"))
  #expect(document.parent?.title == "Sub/folder")
  #expect(document.parent?.isFolder == true)
  #expect(document.parent?.parent?.title == "Engineering")
  #expect(document.parent?.parent?.parent == nil)
}

@Test func localParentNavigationKeepsBookmarkAndRelativePath() {
  let location = HarnessLocation(id: UUID(), name: "Local", bookmark: Data([1, 2, 3]), isFolder: true, drive: nil)
  let document = HarnessDocument(location: location, path: ["Subfolder", "Drawing.pdf"], isFolder: false)
  #expect(document.title == "Drawing")
  #expect(document.parent?.path == ["Subfolder"])
  #expect(document.parent?.location.bookmark == location.bookmark)
  #expect(document.parent?.parent?.path == [])
  #expect(document.parent?.parent?.parent == nil)
}
