import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HarnessDriveItem: Codable, Identifiable, Sendable, Equatable {
  static let folderType = "application/vnd.google-apps.folder"
  static let pdfType = "application/pdf"
  let id: String
  let name: String
  let mimeType: String
  var parents: [String]?
  var trashed: Bool?
  var size: String?
  var capabilities: Capabilities?
  struct Capabilities: Codable, Sendable, Equatable {
    var canDownload: Bool?
  }
  var isFolder: Bool { mimeType == Self.folderType }
}

enum HarnessDriveError: LocalizedError, Equatable {
  case configure, signIn, wrongAccount, permission, unavailable, invalidResponse
  case invalidID, notFolder, notPDF, moved, tooLarge, tooManyItems

  var errorDescription: String? {
    switch self {
    case .configure: "Google Drive is not configured for this build. Ask the app owner to enable Google sign-in."
    case .signIn: "Sign in to Google Drive on your phone, then reopen the folder."
    case .wrongAccount: "This folder belongs to another saved Google connection. Sign in with the account that selected it."
    case .permission: "Google denied access. Check your Drive permissions and read-only consent, then reconnect if needed."
    case .unavailable: "Google Drive could not be reached. Check your connection and try again."
    case .invalidResponse: "Google Drive returned an unexpected response. Try again."
    case .invalidID: "The saved Drive reference is invalid. Select the folder again."
    case .notFolder: "This Drive location is no longer a folder. Select another folder."
    case .notPDF: "Choose a downloadable, unlocked PDF. Google Docs and shortcuts are not supported."
    case .moved: "This item moved outside its saved folder or was deleted. Reopen its folder or select it again."
    case .tooLarge: "This PDF exceeds the 25 MB reading limit. Choose a smaller PDF."
    case .tooManyItems: "This folder is too large to list completely. Select a smaller subfolder."
    }
  }
}

// Foundation-only API code, also compiled directly into the iOS target. Tokens
// are supplied per operation, never stored in folder metadata or page URLs.
struct HarnessDriveAPI: Sendable {
  typealias Transport = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
  static let pdfLimit = 25 * 1024 * 1024
  private static let fields = "id,name,mimeType,parents,trashed,size,capabilities(canDownload)"
  let transport: Transport

  static func validateID(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 256,
          value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
      throw HarnessDriveError.invalidID
    }
  }

  func item(_ id: String, parent: String? = nil, token: String) async throws -> HarnessDriveItem {
    try Self.validateID(id)
    let data = try await request(path: "files/" + id,
      query: [URLQueryItem(name: "fields", value: Self.fields), URLQueryItem(name: "supportsAllDrives", value: "true")], token: token)
    let item = try decode(HarnessDriveItem.self, data)
    try Self.validateID(item.id)
    guard item.id == id || id == "root", item.trashed != true else { throw HarnessDriveError.moved }
    if let parent, item.parents?.contains(parent) != true { throw HarnessDriveError.moved }
    return item
  }

  func children(_ parent: String, token: String, foldersOnly: Bool = false) async throws -> [HarnessDriveItem] {
    try Self.validateID(parent)
    let types = foldersOnly ? "mimeType = '\(HarnessDriveItem.folderType)'"
      : "(mimeType = '\(HarnessDriveItem.folderType)' or mimeType = '\(HarnessDriveItem.pdfType)')"
    var result: [HarnessDriveItem] = []
    var cursor: String?
    var seenCursors = Set<String>()
    repeat {
      var query = [
        URLQueryItem(name: "q", value: "'\(parent)' in parents and trashed = false and \(types)"),
        URLQueryItem(name: "fields", value: "nextPageToken,incompleteSearch,files(\(Self.fields))"),
        URLQueryItem(name: "pageSize", value: "100"),
        URLQueryItem(name: "orderBy", value: "name_natural"),
        URLQueryItem(name: "supportsAllDrives", value: "true"),
        URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
      ]
      if let cursor { query.append(URLQueryItem(name: "pageToken", value: cursor)) }
      let data = try await request(path: "files", query: query, token: token)
      let page = try decode(FileList.self, data)
      guard page.incompleteSearch != true else { throw HarnessDriveError.invalidResponse }
      for item in page.files {
        try Self.validateID(item.id)
        guard item.trashed != true,
              item.parents?.contains(parent) == true,
              item.isFolder || (!foldersOnly && item.mimeType == HarnessDriveItem.pdfType) else { continue }
        result.append(item)
      }
      guard result.count <= 10_000 else { throw HarnessDriveError.tooManyItems }
      cursor = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
      if let cursor, !seenCursors.insert(cursor).inserted { throw HarnessDriveError.invalidResponse }
      guard seenCursors.count <= 100 else { throw HarnessDriveError.tooManyItems }
    } while cursor != nil
    // Pagination can repeat entries when a folder changes while it is listed.
    var seen = Set<String>()
    return result.filter { seen.insert($0.id).inserted }.sorted {
      if $0.isFolder != $1.isFolder { return $0.isFolder }
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  func descendant(root: String, path: [String], token: String) async throws -> HarnessDriveItem {
    var current = try await item(root, token: token)
    guard current.isFolder else { throw HarnessDriveError.notFolder }
    for id in path {
      guard current.isFolder else { throw HarnessDriveError.notFolder }
      current = try await item(id, parent: current.id, token: token)
    }
    return current
  }

  func pdf(_ id: String, parent: String, token: String) async throws -> Data {
    // Recheck type, membership, deletion and download permission on every open.
    let item = try await item(id, parent: parent, token: token)
    guard item.mimeType == HarnessDriveItem.pdfType, item.capabilities?.canDownload != false else { throw HarnessDriveError.notPDF }
    if let size = item.size {
      guard let bytes = Int64(size), bytes >= 0 else { throw HarnessDriveError.invalidResponse }
      guard bytes <= Self.pdfLimit else { throw HarnessDriveError.tooLarge }
    }
    let data = try await request(path: "files/" + id,
      query: [URLQueryItem(name: "alt", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true")],
      token: token, limit: Self.pdfLimit)
    guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { throw HarnessDriveError.notPDF }
    return data
  }

  private struct FileList: Decodable {
    let files: [HarnessDriveItem]
    var nextPageToken: String?
    var incompleteSearch: Bool?
  }

  private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw HarnessDriveError.invalidResponse }
  }

  private func request(path: String, query: [URLQueryItem], token: String, limit: Int = 4 * 1024 * 1024) async throws -> Data {
    guard !token.isEmpty else { throw HarnessDriveError.signIn }
    var components = URLComponents(string: "https://www.googleapis.com/drive/v3/" + path)!
    components.queryItems = query
    guard let url = components.url else { throw HarnessDriveError.invalidID }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 60
    let data: Data
    let response: HTTPURLResponse
    do { (data, response) = try await transport(request, limit) }
    catch let error as HarnessDriveError { throw error }
    catch is CancellationError { throw CancellationError() }
    catch { throw HarnessDriveError.unavailable }
    switch response.statusCode {
    case 200: break
    case 401: throw HarnessDriveError.signIn
    case 403: throw HarnessDriveError.permission
    case 404: throw HarnessDriveError.moved
    default: throw HarnessDriveError.unavailable
    }
    guard data.count <= limit else { throw HarnessDriveError.tooLarge }
    return data
  }
}
