import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HarnessDriveCore

private actor DriveStub {
  struct Reply: Sendable {
    let status: Int
    let data: Data
    init(_ json: String, status: Int = 200) { self.status = status; data = Data(json.utf8) }
    init(data: Data) { status = 200; self.data = data }
  }
  private var replies: [Reply]
  private(set) var requests: [URLRequest] = []
  private(set) var limits: [Int] = []
  init(_ replies: [Reply]) { self.replies = replies }
  func fetch(_ request: URLRequest, limit: Int) throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    limits.append(limit)
    guard !replies.isEmpty else { throw HarnessDriveError.invalidResponse }
    let reply = replies.removeFirst()
    return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
  }
  nonisolated var api: HarnessDriveAPI {
    HarnessDriveAPI { try await self.fetch($0, limit: $1) }
  }
}

private let pdfMetadata = #"{"id":"pdf_1","name":"Drawing.pdf","mimeType":"application/pdf","parents":["folder_1"],"size":"40","capabilities":{"canDownload":true}}"#

@Test func rootResolvesToStableFolderID() async throws {
  let stub = DriveStub([.init(#"{"id":"actual_root","name":"My Drive","mimeType":"application/vnd.google-apps.folder"}"#)])
  let item = try await stub.api.item("root", token: "test-token")
  #expect(item.id == "actual_root")
  #expect(item.isFolder)
}

@Test func listingPaginatesFiltersAndSortsWithoutLosingFolders() async throws {
  let stub = DriveStub([
    .init(#"{"nextPageToken":"cursor + /","files":[{"id":"pdf_2","name":"B.pdf","mimeType":"application/pdf","parents":["folder_1"]},{"id":"shortcut","name":"Alias","mimeType":"application/vnd.google-apps.shortcut","parents":["folder_1"]}]}"#),
    .init(#"{"files":[{"id":"subfolder","name":"Z folder","mimeType":"application/vnd.google-apps.folder","parents":["folder_1"]},{"id":"pdf_1","name":"A.pdf","mimeType":"application/pdf","parents":["folder_1"]},{"id":"pdf_2","name":"B.pdf","mimeType":"application/pdf","parents":["folder_1"]},{"id":"outside","name":"Other.pdf","mimeType":"application/pdf","parents":["other"]}]}"#)
  ])
  let items = try await stub.api.children("folder_1", token: "test-token")
  #expect(items.map(\.id) == ["subfolder", "pdf_1", "pdf_2"])
  let requests = await stub.requests
  #expect(requests.count == 2)
  let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
  #expect(query.first(where: { $0.name == "pageToken" })?.value == "cursor + /")
  #expect(query.first(where: { $0.name == "q" })?.value?.contains("'folder_1' in parents and trashed = false") == true)
  #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "www.googleapis.com" })
  #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
  #expect(requests.allSatisfy { $0.url?.absoluteString.contains("test-token") == false })
}

@Test func invalidIDsCannotChangeTheQueryOrPath() async {
  let stub = DriveStub([])
  for id in ["", "../secret", "a' or trashed = true", "a/b", "a?alt=media"] {
    await #expect(throws: HarnessDriveError.invalidID) { try await stub.api.children(id, token: "test-token") }
    await #expect(throws: HarnessDriveError.invalidID) { try await stub.api.item(id, token: "test-token") }
  }
  #expect(await stub.requests.isEmpty)
}

@Test func repeatedPageTokenAndIncompleteSearchFailRatherThanShowPartialResults() async {
  let stub = DriveStub([.init(#"{"files":[],"nextPageToken":"again"}"#), .init(#"{"files":[],"nextPageToken":"again"}"#)])
  await #expect(throws: HarnessDriveError.invalidResponse) { try await stub.api.children("folder_1", token: "test-token") }
  let incomplete = DriveStub([.init(#"{"files":[],"incompleteSearch":true}"#)])
  await #expect(throws: HarnessDriveError.invalidResponse) { try await incomplete.api.children("folder_1", token: "test-token") }
}

@Test func movedPDFIsNotDownloaded() async {
  let stub = DriveStub([.init(#"{"id":"pdf_1","name":"Moved.pdf","mimeType":"application/pdf","parents":["elsewhere"]}"#)])
  await #expect(throws: HarnessDriveError.moved) { try await stub.api.pdf("pdf_1", parent: "folder_1", token: "test-token") }
  #expect(await stub.requests.count == 1)
}

@Test func deletedPDFIsNotDownloaded() async {
  let stub = DriveStub([.init(#"{"id":"pdf_1","name":"Deleted.pdf","mimeType":"application/pdf","parents":["folder_1"],"trashed":true}"#)])
  await #expect(throws: HarnessDriveError.moved) { try await stub.api.pdf("pdf_1", parent: "folder_1", token: "test-token") }
  #expect(await stub.requests.count == 1)
}

@Test func nonPDFAndDisabledDownloadAreRejected() async {
  for json in [
    #"{"id":"pdf_1","name":"Doc","mimeType":"application/vnd.google-apps.document","parents":["folder_1"]}"#,
    #"{"id":"pdf_1","name":"Locked.pdf","mimeType":"application/pdf","parents":["folder_1"],"capabilities":{"canDownload":false}}"#
  ] {
    let stub = DriveStub([.init(json)])
    await #expect(throws: HarnessDriveError.notPDF) { try await stub.api.pdf("pdf_1", parent: "folder_1", token: "test-token") }
    #expect(await stub.requests.count == 1)
  }
}

@Test func oversizedMetadataPreventsMediaRequest() async {
  let stub = DriveStub([.init(#"{"id":"pdf_1","name":"Huge.pdf","mimeType":"application/pdf","parents":["folder_1"],"size":"26214401"}"#)])
  await #expect(throws: HarnessDriveError.tooLarge) { try await stub.api.pdf("pdf_1", parent: "folder_1", token: "test-token") }
  #expect(await stub.requests.count == 1)
}

@Test func actualMediaSizeIsCheckedEvenWhenMetadataIsSmall() async {
  let stub = DriveStub([.init(pdfMetadata), .init(data: Data(repeating: 0, count: HarnessDriveAPI.pdfLimit + 1))])
  await #expect(throws: HarnessDriveError.tooLarge) { try await stub.api.pdf("pdf_1", parent: "folder_1", token: "test-token") }
  #expect(await stub.limits.last == HarnessDriveAPI.pdfLimit)
}

@Test func htmlCannotMasqueradeAsAPDF() async {
  let stub = DriveStub([.init(pdfMetadata), .init("<html>sign in</html>")])
  await #expect(throws: HarnessDriveError.notPDF) { try await stub.api.pdf("pdf_1", parent: "folder_1", token: "test-token") }
}

@Test func mediaStaysPrivateAndEachOpenRechecksMetadata() async throws {
  let data = Data("%PDF-1.7\nfixture".utf8)
  let stub = DriveStub([.init(pdfMetadata), .init(data: data), .init("{}", status: 403)])
  #expect(try await stub.api.pdf("pdf_1", parent: "folder_1", token: "test-token") == data)
  await #expect(throws: HarnessDriveError.permission) { try await stub.api.pdf("pdf_1", parent: "folder_1", token: "test-token") }
  let requests = await stub.requests
  #expect(requests.count == 3)
  #expect(requests[0].url?.path == "/drive/v3/files/pdf_1")
  #expect(requests[1].url?.query?.contains("alt=media") == true)
  #expect(requests[2].url?.query?.contains("alt=media") == false)
  #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
}

@Test func authAndMissingFileResponsesHaveActionableErrors() async {
  for (status, expected) in [(401, HarnessDriveError.signIn), (403, .permission), (404, .moved), (503, .unavailable)] {
    let stub = DriveStub([.init("private error details", status: status)])
    await #expect(throws: expected) { try await stub.api.item("folder_1", token: "test-token") }
  }
}

@Test func nestedFolderMustStillBelongToItsSavedRoot() async {
  let stub = DriveStub([
    .init(#"{"id":"folder_1","name":"Selected","mimeType":"application/vnd.google-apps.folder"}"#),
    .init(#"{"id":"nested","name":"Moved","mimeType":"application/vnd.google-apps.folder","parents":["elsewhere"]}"#)
  ])
  await #expect(throws: HarnessDriveError.moved) {
    try await stub.api.descendant(root: "folder_1", path: ["nested", "pdf_1"], token: "test-token")
  }
  #expect(await stub.requests.count == 2)
}

@Test func everyAncestorIsRevalidatedForNestedDocuments() async throws {
  let stub = DriveStub([
    .init(#"{"id":"folder_1","name":"Selected","mimeType":"application/vnd.google-apps.folder"}"#),
    .init(#"{"id":"nested","name":"Subfolder","mimeType":"application/vnd.google-apps.folder","parents":["folder_1"]}"#),
    .init(#"{"id":"pdf_1","name":"Drawing.pdf","mimeType":"application/pdf","parents":["nested"]}"#)
  ])
  let item = try await stub.api.descendant(root: "folder_1", path: ["nested", "pdf_1"], token: "test-token")
  #expect(item.id == "pdf_1")
  #expect(await stub.requests.count == 3)
}

@Test func savedRootCannotBecomeANonFolder() async {
  let stub = DriveStub([.init(pdfMetadata)])
  await #expect(throws: HarnessDriveError.notFolder) {
    try await stub.api.descendant(root: "pdf_1", path: [], token: "test-token")
  }
}
