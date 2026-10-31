import Foundation

struct HarnessDriveLocation: Codable, Sendable {
  let accountID: String
  let folderID: String
}

struct HarnessLocation: Codable, Identifiable, Sendable {
  let id: UUID
  let name: String
  let bookmark: Data
  let isFolder: Bool
  let drive: HarnessDriveLocation?
}

struct HarnessDocument: Identifiable, Sendable {
  let location: HarnessLocation
  let path: [String]
  let isFolder: Bool
  var drivePath: [HarnessDriveItem] = []
  var id: String { location.id.uuidString + "/" + (location.drive == nil ? path : drivePath.map(\.id)).joined(separator: "/") }
  var title: String {
    let name = drivePath.last?.name ?? path.last ?? location.name
    return isFolder ? name : (name as NSString).deletingPathExtension
  }
  var parent: HarnessDocument? {
    if location.drive != nil {
      guard !drivePath.isEmpty else { return nil }
      return HarnessDocument(location: location, path: [], isFolder: true, drivePath: Array(drivePath.dropLast()))
    }
    guard !path.isEmpty else { return nil }
    return HarnessDocument(location: location, path: Array(path.dropLast()), isFolder: true)
  }
}
