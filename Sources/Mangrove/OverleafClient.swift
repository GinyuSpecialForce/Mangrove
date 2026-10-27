import Foundation

/// A native Overleaf client built on the endpoints the Overleaf web app itself uses.
///
/// Overleaf has no public API for reading and writing existing projects, so this
/// talks to the same session-authenticated routes as the web editor:
///
///   GET  /user/projects                                  list projects
///   GET  /dev/csrf                                       CSRF token (plain text)
///   GET  /Project/:id/download/zip                       whole project as a zip
///   POST /Project/:id/upload                             write a file (multipart, `qqfile`)
///   POST /project/:id/compile                            compile
///   GET  /download/project/:id/build/:build/output/…     compiled artefacts (PDF, log)
///
/// Requests carry the session cookie from the Keychain; POSTs additionally carry
/// an `x-csrf-token` header, and any session cookie refreshed by a response is
/// fed back so the CSRF secret stays in sync.
final class OverleafClient {

    /// Used for API requests: a desktop Safari user agent plus an honest app token.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/16.0 Safari/605.1.15 Mangrove/1.0"

    /// Used for the embedded sign-in web view, where Overleaf and the identity
    /// providers it delegates to expect an ordinary browser.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/16.0 Safari/605.1.15"

    private(set) var session: StoredSession
    private(set) var baseURL: URL
    private var csrf: String?
    private let urlSession: URLSession

    /// Root folder ids, keyed by project.
    ///
    /// `POST /Project/:id/upload` refuses to write without a `folder_id`, and no
    /// HTTP route exposes one, so the id comes from the realtime channel's
    /// `joinProjectResponse`. One lookup per project is enough for the run.
    private var rootFolderIds: [String: String] = [:]
    private var joinsInFlight: [String: Task<String, Error>] = [:]

    /// Called whenever Overleaf refreshes our session cookies, so the caller can
    /// persist them (the CSRF secret lives in the session).
    var onSessionUpdate: ((StoredSession) -> Void)?

    init(session: StoredSession) {
        self.session = session
        self.baseURL = URL(string: session.baseURL) ?? URL(string: "https://www.overleaf.com")!
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 600
        self.urlSession = URLSession(
            configuration: config,
            delegate: RedirectBlocker(),
            delegateQueue: nil
        )
    }

    // MARK: - Request plumbing

    private func makeRequest(path: String, method: String = "GET", absolute: Bool = false) throws -> URLRequest {
        let url: URL
        if absolute, let direct = URL(string: path) {
            url = direct
        } else if let relative = URL(string: path, relativeTo: baseURL) {
            url = relative.absoluteURL
        } else {
            throw MangroveError.message("Could not build a request for \(path).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let cookieHeader = session.cookieHeader()
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MangroveError.message("Overleaf sent a response this app could not read.")
        }
        mergeCookies(from: http)

        // The session expired and Overleaf redirected us to the login page.
        if http.statusCode == 401 {
            throw MangroveError.notAuthenticated
        }
        if http.statusCode == 302 || http.statusCode == 303 {
            let location = http.value(forHTTPHeaderField: "Location") ?? ""
            if location.isEmpty || location.contains("/login") {
                throw MangroveError.notAuthenticated
            }
            throw MangroveError.message("Overleaf redirected this request to \(location).")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MangroveError.http(status: http.statusCode, body: Self.describe(body: data))
        }
        return (data, http)
    }

    /// When a request fails, Overleaf answers with a full HTML error page rather
    /// than JSON. Showing that markup to someone is useless, so reduce it to the
    /// page title (or drop it) and only pass through short plain-text bodies.
    static func describe(body data: Data) -> String {
        let text = String(decoding: data.prefix(4000), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        guard text.hasPrefix("<") else { return String(text.prefix(180)) }

        if let open = text.range(of: "<title[^>]*>", options: .regularExpression),
           let close = text.range(of: "</title>", options: .regularExpression, range: open.upperBound..<text.endIndex) {
            let title = text[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return ""
    }

    /// Overleaf refreshes `overleaf_session2` whenever it needs to (notably when we
    /// fetch a CSRF token, because csurf stores its secret in the session). If we
    /// dropped those we would keep sending a session without the CSRF secret.
    private func mergeCookies(from response: HTTPURLResponse) {
        var headerValues: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, name.lowercased() == "set-cookie" else { continue }
            if let text = value as? String { headerValues.append(text) }
        }
        guard !headerValues.isEmpty else { return }

        // URLSession coalesces repeated Set-Cookie headers with ", ". Cookie values
        // are not allowed to contain a bare "name=" after a comma, so split there.
        let joined = headerValues.joined(separator: ", ")
        let parts = joined.split(separator: ",").reduce(into: [String]()) { result, piece in
            let candidate = String(piece).trimmingCharacters(in: .whitespaces)
            let looksLikeNewCookie = candidate.range(
                of: "^[A-Za-z0-9_.\\-]+=", options: .regularExpression
            ) != nil
            if looksLikeNewCookie || result.isEmpty {
                result.append(candidate)
            } else {
                result[result.count - 1] += ", " + candidate
            }
        }

        var changed = false
        for header in parts {
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": header], for: response.url ?? baseURL
            )
            for cookie in parsed {
                guard let record = CookieRecord(cookie: cookie) else { continue }
                if let index = session.cookies.firstIndex(where: { $0.name == record.name && $0.domain == record.domain }) {
                    if session.cookies[index] != record {
                        session.cookies[index] = record
                        changed = true
                    }
                } else {
                    session.cookies.append(record)
                    changed = true
                }
            }
        }
        if changed {
            session.savedAt = Date()
            onSessionUpdate?(session)
        }
    }

    private func getJSON<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, _) = try await perform(try makeRequest(path: path))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MangroveError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Session

    /// Cheap "is this session still good?" check. Used after sign-in and at launch.
    func verifySession() async -> Bool {
        do {
            let _: ProjectsResponse = try await getJSON("/user/projects", as: ProjectsResponse.self)
            return true
        } catch {
            return false
        }
    }

    /// The CSRF token is a plain-text GET endpoint that the web app uses too.
    func csrfToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let csrf, !csrf.isEmpty { return csrf }
        let (data, _) = try await perform(try makeRequest(path: "/dev/csrf"))
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw MangroveError.message("Overleaf did not return a CSRF token.")
        }
        csrf = token
        return token
    }

    // MARK: - Projects

    func fetchProjects() async throws -> [OverleafProject] {
        let response = try await getJSON("/user/projects", as: ProjectsResponse.self)
        return response.projects.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Content

    /// Downloads the whole project as a zip. This is the one cookie-authenticated
    /// route that returns file *contents*, so the app keeps a real local working copy.
    func downloadProjectZip(_ projectId: String) async throws -> Data {
        let request = try makeRequest(path: "/Project/\(projectId)/download/zip")
        let (data, _) = try await perform(request)
        guard data.count > 3 else {
            throw MangroveError.zipFailed("Overleaf returned an empty archive.")
        }
        return data
    }

    /// Writes a file to Overleaf, creating it if it does not exist yet.
    ///
    /// Overleaf's upload route resolves the destination folder from `folder_id`
    /// and then walks `relativePath` from there, creating folders as needed, so
    /// the project's root folder id is all that is required.
    func saveFile(projectId: String, relativePath: String, contents: Data) async throws {
        let folderId = try await rootFolderId(projectId: projectId)
        do {
            try await uploadFile(
                projectId: projectId, folderId: folderId, relativePath: relativePath, contents: contents
            )
            SyncDiagnostics.write("upload ok \(relativePath) (\(contents.count) bytes)")
        } catch {
            // A cached id can go stale if the folder was recreated on Overleaf's
            // side; re-read it once before giving up.
            guard Self.isFolderNotFound(error) else {
                SyncDiagnostics.write(
                    "upload failed \(relativePath): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                )
                throw error
            }
            rootFolderIds[projectId] = nil
            let refreshed = try await rootFolderId(projectId: projectId)
            try await uploadFile(
                projectId: projectId, folderId: refreshed, relativePath: relativePath, contents: contents
            )
            SyncDiagnostics.write("upload ok after folder refresh \(relativePath)")
        }
    }

    /// The project's root folder id, fetched over the realtime channel and cached.
    func rootFolderId(projectId: String) async throws -> String {
        if let cached = rootFolderIds[projectId] { return cached }
        // Several files often save at once; share one socket handshake between them.
        if let existing = joinsInFlight[projectId] {
            return try await existing.value
        }

        let task = Task<String, Error> { [baseURL, session] in
            let channel = RealtimeChannel(
                baseURL: baseURL,
                cookieHeader: session.cookieHeader(),
                userAgent: Self.userAgent,
                log: { SyncDiagnostics.write($0) }
            )
            let join = try await channel.joinProject(projectId)
            guard let id = join.rootFolderId, !id.isEmpty else {
                throw MangroveError.message(
                    "Overleaf did not report the project's folder structure, which is needed to save files."
                )
            }
            return id
        }
        joinsInFlight[projectId] = task
        defer { joinsInFlight[projectId] = nil }

        do {
            let id = try await task.value
            rootFolderIds[projectId] = id
            SyncDiagnostics.write("joined project \(projectId) over realtime")
            return id
        } catch {
            SyncDiagnostics.write("realtime join failed for \(projectId): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            throw error
        }
    }

    /// Overleaf answers a missing `folder_id` with 404 (its `findElement` throws) and
    /// an unresolvable folder with 422 `folder_not_found`. Both mean the cached id
    /// is no longer usable, so both are worth one refresh.
    private static func isFolderNotFound(_ error: Error) -> Bool {
        guard case let MangroveError.http(status, body) = error else { return false }
        return status == 404 || body.contains("folder_not_found")
    }

    /// Creates or overwrites a single file in the project.
    private func uploadFile(
        projectId: String, folderId: String, relativePath: String, contents: Data
    ) async throws {
        let filename = (relativePath as NSString).lastPathComponent
        let boundary = "----Mangrove\(UUID().uuidString)"

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        field("name", filename)
        field("relativePath", relativePath)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"qqfile\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(contents)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        // `folder_id` is a query parameter, and `relativePath` is the path from
        // that folder to the file (folders along the way are created for us).
        let encodedFolder = folderId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folderId
        var request = try makeRequest(
            path: "/Project/\(projectId)/upload?folder_id=\(encodedFolder)", method: "POST"
        )
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, _) = try await performAuthorized(request)

        // Overleaf answers with {success: true, entity_id, entity_type}, or with
        // success:false plus a machine-readable reason.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool, success == false {
            let reason = json["error"] as? String ?? ""
            throw MangroveError.http(status: 422, body: reason.isEmpty ? "rejected" : reason)
        }
    }

    // MARK: - Compile

    /// Runs a compile. The root document is whatever the project has configured,
    /// so no document ids are needed.
    func compile(projectId: String, draft: Bool) async throws -> CompileResult {
        let payload: [String: Any] = [
            "draft": draft,
            "check": "silent",
            "incrementalCompilesEnabled": true,
            "stopOnFirstError": false
        ]
        var request = try makeRequest(path: "/project/\(projectId)/compile", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await performAuthorized(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MangroveError.decoding("The compile response was not valid JSON.")
        }
        if let error = json["error"] as? String {
            throw MangroveError.compileFailed(error)
        }
        let status = json["status"] as? String ?? "unknown"
        let outputs = (json["outputFiles"] as? [[String: Any]] ?? []).compactMap(OutputFile.init(json:))
        return CompileResult(
            status: status,
            outputFiles: outputs,
            clsiServerId: json["clsiServerId"] as? String,
            pdfDownloadDomain: json["pdfDownloadDomain"] as? String,
            outputUrlPrefix: json["outputUrlPrefix"] as? String,
            rawJSON: json
        )
    }

    /// Fetches one compiled artefact (the PDF, or `output.log` when something failed).
    func download(output: OutputFile, from compile: CompileResult, projectId: String) async throws -> Data {
        var candidates: [String] = []

        if let raw = output.url, !raw.isEmpty {
            if raw.hasPrefix("http") {
                candidates.append(appendingClsiServer(to: raw, compile: compile))
            } else if let domain = compile.pdfDownloadDomain, !domain.isEmpty, domain.hasPrefix("http") {
                candidates.append(appendingClsiServer(to: domain + raw, compile: compile))
            } else if let prefix = compile.outputUrlPrefix, !prefix.isEmpty, prefix.hasPrefix("http") {
                candidates.append(appendingClsiServer(to: prefix + raw, compile: compile))
            } else {
                candidates.append(appendingClsiServer(to: raw, compile: compile))
            }
        }
        // Fallback: the documented "download this build" path.
        if let buildId = compile.buildId {
            candidates.append("/download/project/\(projectId)/build/\(buildId)/output/\(output.path)")
        }

        var lastError: Error = MangroveError.message("Overleaf did not offer a download link for \(output.path).")
        for candidate in candidates {
            do {
                let isAbsolute = candidate.hasPrefix("http")
                var request = try makeRequest(path: candidate, absolute: isAbsolute)
                if output.path.hasSuffix(".pdf") {
                    request.setValue("application/pdf", forHTTPHeaderField: "Accept")
                }
                let (data, _) = try await perform(request)
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func appendingClsiServer(to url: String, compile: CompileResult) -> String {
        guard let server = compile.clsiServerId, !server.isEmpty else { return url }
        guard !url.contains("clsiserverid=") else { return url }
        let separator = url.contains("?") ? "&" : "?"
        return url + separator + "clsiserverid=" + server
    }

    // MARK: - CSRF-aware writes

    /// Performs a POST, obtaining a CSRF token first and retrying once with a
    /// freshly issued token if Overleaf rejects it.
    private func performAuthorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var token = try await csrfToken()
        var attempt = request
        attempt.setValue(token, forHTTPHeaderField: "x-csrf-token")

        do {
            return try await perform(attempt)
        } catch let error as MangroveError {
            guard case let .http(status, _) = error, status == 403 else { throw error }
            token = try await csrfToken(forceRefresh: true)
            attempt.setValue(token, forHTTPHeaderField: "x-csrf-token")
            return try await perform(attempt)
        }
    }
}

/// Overleaf redirects to `/login` when the session is gone. Following that
/// redirect would hand us an HTML login page where we expect JSON, so we refuse
/// redirects and inspect the 302 ourselves.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
