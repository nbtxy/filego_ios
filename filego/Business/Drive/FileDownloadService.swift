import Foundation

enum FileDownloadService {
    @MainActor private static var inFlight: [String: Task<Void, Error>] = [:]

    enum Failure: Error, LocalizedError {
        case invalidResponse

        var errorDescription: String? { "无法下载此文件" }
    }

    @MainActor
    static func download(node: DriveNode, userID: String) async throws -> PreviewTemporaryFile {
        guard let token = AuthTokenStorage.token else { throw FileGoAPIError.unauthorized }
        let baseURL = BackendConfig.baseURL
        if let cachedURL = await FileCacheManager.shared.materializePreview(
            for: node,
            userID: userID,
            baseURL: baseURL
        ) {
            return PreviewTemporaryFile(url: cachedURL)
        }

        guard let blobID = node.blobId,
              node.size <= FileCacheManager.capacityBytes,
              await FileCacheManager.shared.isAvailable() else {
            return try await downloadWithoutCache(node: node, token: token, baseURL: baseURL)
        }
        let key = FileCacheManager.downloadKey(
            blobID: blobID,
            userID: userID,
            baseURL: baseURL
        )
        let task: Task<Void, Error>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let created = Task {
                try await downloadIntoCache(
                    node: node,
                    token: token,
                    userID: userID,
                    baseURL: baseURL
                )
            }
            inFlight[key] = created
            task = created
        }
        defer { inFlight[key] = nil }
        try await task.value
        try Task.checkCancellation()
        guard let cachedURL = await FileCacheManager.shared.materializePreview(
            for: node,
            userID: userID,
            baseURL: baseURL
        ) else { throw Failure.invalidResponse }
        return PreviewTemporaryFile(url: cachedURL)
    }

    private static func downloadIntoCache(
        node: DriveNode,
        token: String,
        userID: String,
        baseURL: URL
    ) async throws {
        let temporaryURL = try await downloadURL(node: node, token: token, baseURL: baseURL)
        do {
            try await FileCacheManager.shared.storeDownloadedFile(
                at: temporaryURL,
                node: node,
                userID: userID,
                baseURL: baseURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func downloadWithoutCache(
        node: DriveNode,
        token: String,
        baseURL: URL
    ) async throws -> PreviewTemporaryFile {
        let temporaryURL = try await downloadURL(node: node, token: token, baseURL: baseURL)
        let directory = PreviewTemporaryFile.rootDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(node.name)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return PreviewTemporaryFile(url: destination)
    }

    private static func downloadURL(
        node: DriveNode,
        token: String,
        baseURL: URL
    ) async throws -> URL {
        let remoteURL = baseURL
            .appendingPathComponent("nodes")
            .appendingPathComponent(node.id)
            .appendingPathComponent("download")
        var request = URLRequest(url: remoteURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              http.mimeType?.lowercased() != "application/json" else {
            throw Failure.invalidResponse
        }

        return temporaryURL
    }
}
