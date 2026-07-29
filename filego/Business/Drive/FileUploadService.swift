import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum FileUploadService {
    enum Failure: Error, LocalizedError {
        case cannotReadFile
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .cannotReadFile: return "无法读取所选文件"
            case .invalidResponse: return "服务器未确认文件上传"
            }
        }
    }

    @MainActor
    static func upload(
        fileURL: URL,
        parentId: String,
        session: SessionManager,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> DriveNode {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }

        let metadata = try await Task.detached { try fileMetadata(at: fileURL) }.value
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let initialized: UploadInitResponse = try await session.request(
            UploadAPI.initialize(
                parentId: parentId,
                name: fileURL.lastPathComponent,
                size: metadata.size,
                mime: mime,
                sha256: metadata.sha256
            )
        )
        if initialized.mode == "instant", let node = initialized.node {
            onProgress(1)
            return node
        }
        guard let sessionId = initialized.sessionId else { throw Failure.invalidResponse }

        do {
            guard let token = AuthTokenStorage.token else { throw FileGoAPIError.unauthorized }
            let url = initialized.uploadUrl.flatMap(URL.init(string:))
                ?? BackendConfig.baseURL
                    .appendingPathComponent("uploads")
                    .appendingPathComponent(sessionId)
                    .appendingPathComponent("content")
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            if initialized.uploadUrl == nil {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue(mime, forHTTPHeaderField: "Content-Type")
            request.setValue(String(metadata.size), forHTTPHeaderField: "Content-Length")

            let delegate = UploadProgressDelegate(onProgress: onProgress)
            let (_, response) = try await URLSession.shared.upload(
                for: request,
                fromFile: fileURL,
                delegate: delegate
            )
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw Failure.invalidResponse
            }
            onProgress(1)
            let completed: UploadCompleteResponse = try await session.request(
                UploadAPI.complete(sessionId: sessionId)
            )
            return completed.node
        } catch {
            let _: UploadAbortResponse? = try? await session.request(
                UploadAPI.abort(sessionId: sessionId)
            )
            throw error
        }
    }

    nonisolated private static func fileMetadata(at url: URL) throws -> (size: Int64, sha256: String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.cannotReadFile }
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !data.isEmpty else { break }
            size += Int64(data.count)
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (size, digest)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @MainActor (Double) -> Void

    init(onProgress: @escaping @MainActor (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        Task { @MainActor [onProgress] in onProgress(fraction) }
    }
}
