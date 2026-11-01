import Foundation

public struct CloudBucket: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let projectID: String
    public init(name: String, projectID: String) { self.name = name; self.projectID = projectID }
}
public struct BucketDiscovery: Sendable {
    public let buckets: [CloudBucket]
    public let warnings: [String]
    public init(buckets: [CloudBucket], warnings: [String]) { self.buckets = buckets; self.warnings = warnings }
}

/// Read-only discovery. A visible bucket is not a promise of object create/get access.
public actor CloudDirectory {
    private let http: HTTPTransport
    private let token: @Sendable (Bool) async throws -> String
    private let delay: @Sendable (Int) async throws -> Void
    public init(http: HTTPTransport = SecureHTTP(), token: @escaping @Sendable (Bool) async throws -> String,
                delay: @escaping @Sendable (Int) async throws -> Void = { attempt in
                    try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 1e9))
                }) {
        self.http = http; self.token = token; self.delay = delay
    }
    private struct Project: Decodable { let projectId: String; let state: String? }
    private struct ProjectPage: Decodable { let projects: [Project]?; let nextPageToken: String? }
    private struct Bucket: Decodable { let name: String }
    private struct BucketPage: Decodable { let items: [Bucket]?; let nextPageToken: String? }

    private func get<T: Decodable>(_ endpoint: String, query: [URLQueryItem], as type: T.Type) async throws -> T {
        var components = URLComponents(string: endpoint)!
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        for attempt in 0..<3 {
            do {
                for refresh in [false, true] {
                    try Task.checkCancellation()
                    var request = URLRequest(url: components.url!)
                    request.setValue("Bearer " + (try await token(refresh)), forHTTPHeaderField: "Authorization")
                    let (data, response) = try await http.send(request)
                    try Task.checkCancellation()
                    if response.statusCode == 401 && !refresh { continue }
                    guard response.statusCode == 200 else { throw ServiceFailure(status: response.statusCode) }
                    guard let result = try? JSONDecoder().decode(T.self, from: data) else {
                        throw ArchiveError("Google returned an unreadable bucket or project list. Refresh to try again.")
                    }
                    return result
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard attempt < 2, error is NetworkFailure || (error as? ServiceFailure)?.retryable == true else { throw error }
                try await delay(attempt)
            }
        }
        throw ServiceFailure(status: 401)
    }
    private func next(_ value: String?, seen: inout Set<String>) throws -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard seen.insert(value).inserted else { throw ArchiveError("Google repeated a list page. Refresh to try again.") }
        return value
    }
    public func buckets(projectID: String) async throws -> [CloudBucket] {
        let project = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, project.count <= 128,
              project.range(of: "^[a-zA-Z0-9:.-]+$", options: .regularExpression) != nil else {
            throw ArchiveError("Enter the Google Cloud project ID or number, not its display name.")
        }
        var result: [CloudBucket] = [], cursor: String?, seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "project", value: project), .init(name: "projection", value: "noAcl"),
                         .init(name: "maxResults", value: "1000"), .init(name: "fields", value: "items/name,nextPageToken")]
            if let cursor { query.append(.init(name: "pageToken", value: cursor)) }
            let page = try await get("https://storage.googleapis.com/storage/v1/b", query: query, as: BucketPage.self)
            for bucket in page.items ?? [] {
                try ArchiveConfiguration.validateBucket(bucket.name)
                result.append(CloudBucket(name: bucket.name, projectID: project))
            }
            cursor = try next(page.nextPageToken, seen: &seen)
        } while cursor != nil
        return Array(Dictionary(result.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }).values).sorted { $0.name < $1.name }
    }
    public func discover() async throws -> BucketDiscovery {
        var projects: [String] = [], cursor: String?, seen = Set<String>()
        do {
            repeat {
                var query = [URLQueryItem(name: "pageSize", value: "100"), .init(name: "query", value: "state:ACTIVE")]
                if let cursor { query.append(.init(name: "pageToken", value: cursor)) }
                let page = try await get("https://cloudresourcemanager.googleapis.com/v3/projects:search", query: query, as: ProjectPage.self)
                projects += (page.projects ?? []).filter { $0.state == nil || $0.state == "ACTIVE" }.map(\.projectId)
                cursor = try next(page.nextPageToken, seen: &seen)
            } while cursor != nil
        } catch let error as ServiceFailure where error.status == 403 {
            throw ArchiveError("Google could not list projects. Sign in again to grant project discovery access. Your administrator may also need to enable the Cloud Resource Manager API or grant project viewing access. You can enter a project ID or bucket name below.")
        }
        var result: [CloudBucket] = [], warnings: [String] = []
        for project in Set(projects).sorted() {
            try Task.checkCancellation()
            do { result += try await buckets(projectID: project) }
            catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if error is AuthenticationFailure || (error as? ServiceFailure)?.status == 401 { throw error }
                warnings.append("Could not list buckets in \(project). Check project permissions or try this project again below.")
            }
        }
        return BucketDiscovery(buckets: result.sorted { $0.name < $1.name }, warnings: warnings)
    }
}
