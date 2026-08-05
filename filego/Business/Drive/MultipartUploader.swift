import Foundation

/// 分片上传执行器：按服务端给的 `chunkSize` 切片，并发直传 R2 预签名 URL，
/// 每片传完回报 etag，最后由调用方去 `POST /uploads/{id}/complete` 合片。
///
/// 刻意**不加**全局 actor 隔离。`FileUploadService.upload` 是 `@MainActor`，
/// 调用这里的非隔离 async 方法会自动跳到协作线程池；又因为是 `await` 内联而不是
/// `Task.detached`，调用方那句 `defer { stopAccessingSecurityScopedResource() }`
/// 在整个传输期间都还有效——用 detached 会提前释放安全作用域，文件读到一半失败。
final class MultipartUploader: Sendable {
    /// 并发 3 片。再高对移动网络收益有限，而内存是 并发数 × chunkSize。
    private static let maxConcurrentParts = 3
    private static let maxRetriesPerPart = 3

    private let sessionId: String
    private let totalSize: Int64
    private let chunkSize: Int64
    private let session: SessionManager
    private let tracker: UploadProgressTracker
    private let reader: FileChunkReader
    private let urls: PartURLProvider

    init(
        fileURL: URL,
        sessionId: String,
        totalSize: Int64,
        chunkSize: Int64,
        initialParts: [UploadPartDescriptor],
        session: SessionManager,
        tracker: UploadProgressTracker
    ) throws {
        self.sessionId = sessionId
        self.totalSize = totalSize
        self.chunkSize = chunkSize
        self.session = session
        self.tracker = tracker
        self.reader = try FileChunkReader(url: fileURL, chunkSize: chunkSize, totalSize: totalSize)
        self.urls = PartURLProvider(sessionId: sessionId, session: session, seed: initialParts)
    }

    func run() async throws {
        defer { Task { [reader] in await reader.close() } }

        // 续传：服务端已记录的片直接跳过。目前 sessionId 不跨启动持久化，所以
        // 这条路径只在同一次调用内生效；接口已接好，将来持久化 sessionId 即可续传。
        let status: UploadStatusResponse = try await session.request(
            UploadAPI.status(sessionId: sessionId)
        )
        let done = Set(status.uploadedParts.map(\.partNumber))
        await tracker.seedCompleted(bytes: status.uploadedParts.reduce(0) { $0 + $1.size })

        let partCount = Int((totalSize + chunkSize - 1) / chunkSize)
        guard partCount > 0 else { return }
        var pending = (1...partCount).filter { !done.contains($0) }.makeIterator()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var started = 0
            while started < Self.maxConcurrentParts, let part = pending.next() {
                group.addTask { [self] in try await uploadPart(part) }
                started += 1
            }
            // 每完成一个补一个，在飞的窗口恒为 maxConcurrentParts。
            // 这里必须 continue 而不是 break：break 会跳过仍在飞的任务。
            while try await group.next() != nil {
                guard let part = pending.next() else { continue }
                group.addTask { [self] in try await uploadPart(part) }
            }
        }
    }

    // MARK: - 单片

    private func uploadPart(_ partNumber: Int) async throws {
        var attempt = 0
        var resigned = false
        while true {
            do {
                try Task.checkCancellation()
                let data = try await reader.chunk(at: partNumber)
                guard
                    let raw = try await urls.uploadURL(for: partNumber),
                    let url = URL(string: raw)
                else {
                    throw FileUploadService.Failure.directUploadUnavailable
                }
                let etag = try await putPresigned(url: url, data: data, partNumber: partNumber)
                let _: UploadPartRecorded = try await session.request(
                    UploadAPI.reportPart(
                        sessionId: sessionId,
                        partNumber: partNumber,
                        etag: etag,
                        size: Int64(data.count)
                    )
                )
                await tracker.finish(part: partNumber, size: Int64(data.count))
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let FileGoAPIError.http(status) where status == 403 && !resigned {
                // 预签名过期。签发时给的是 24h，但上传排队久了仍可能过期：
                // 丢掉缓存重签这一页再试一次，不计入重试次数。
                resigned = true
                await urls.invalidate(from: partNumber)
                await tracker.reset(part: partNumber)
            } catch {
                attempt += 1
                guard attempt <= Self.maxRetriesPerPart, Self.isRetryable(error) else { throw error }
                await tracker.reset(part: partNumber)
                // 0.5 / 1 / 2 秒 + 抖动，避免三片同时重试撞在一起
                let backoff = 0.5 * pow(2, Double(attempt - 1)) + Double.random(in: 0...0.3)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    private func putPresigned(url: URL, data: Data, partNumber: Int) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        // 三条容易踩的规则：
        // 1. 绝不加 Authorization——预签名走 query 签名，多带一个 Authorization 头
        //    会让 R2 改走 header 签名校验并直接 403。
        // 2. 不加 Content-Type——aws4fetch 的 signQuery 只签了 host，请求头保持最小化最安全。
        // 3. 不手设 Content-Length——URLSession 按 body 自己算。
        let delegate = PartProgressDelegate(partNumber: partNumber, tracker: tracker)
        let (_, response) = try await URLSession.shared.upload(
            for: request,
            from: data,
            delegate: delegate
        )
        guard let http = response as? HTTPURLResponse else {
            throw FileUploadService.Failure.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw FileGoAPIError.http(status: http.statusCode)
        }
        guard let etag = http.value(forHTTPHeaderField: "ETag") else {
            throw FileUploadService.Failure.invalidResponse
        }
        // R2 的 ETag 响应头带引号，而服务端 binding 拿到的不带。服务端也会归一化，
        // 这里顺手去掉，免得日志里两种形态混着看不出问题。
        return etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [
                .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost
            ].contains(urlError.code)
        }
        if case let FileGoAPIError.http(status) = error {
            return status >= 500 || status == 429
        }
        // 业务错误（分片大小不正确、片号无效…）重试一万次也是同样的结果
        return false
    }
}

// MARK: - 切片读取

/// 单个 `FileHandle` 的 seek+read 不是并发安全的，用 actor 串起来。
/// 内存占用上限是 `并发数 × chunkSize`，整个文件不会一次进内存。
actor FileChunkReader {
    private let handle: FileHandle
    private let chunkSize: Int64
    private let totalSize: Int64

    init(url: URL, chunkSize: Int64, totalSize: Int64) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw FileUploadService.Failure.cannotReadFile
        }
        self.handle = handle
        self.chunkSize = chunkSize
        self.totalSize = totalSize
    }

    func chunk(at partNumber: Int) throws -> Data {
        let offset = Int64(partNumber - 1) * chunkSize
        let expected = Int(min(chunkSize, totalSize - offset))
        guard expected > 0 else { throw FileUploadService.Failure.cannotReadFile }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: expected) ?? Data()
        // 字节数必须与服务端 partDescriptors 算出的一致，否则回报时会被
        // 40001「分片大小不正确」挡下，重试也没有意义。
        guard data.count == expected else { throw FileUploadService.Failure.cannotReadFile }
        return data
    }

    func close() {
        try? handle.close()
    }
}

// MARK: - 预签名 URL 分页

/// 服务端一次最多签 20 片（`PART_URL_PAGE_SIZE`），更靠后的片要按需续签。
/// 用 actor 保证并发 worker 不会为同一页重复发请求。
actor PartURLProvider {
    private var cache: [Int: String?] = [:]
    private let sessionId: String
    private let session: SessionManager

    init(sessionId: String, session: SessionManager, seed: [UploadPartDescriptor]) {
        self.sessionId = sessionId
        self.session = session
        for part in seed {
            // 注意：值类型是 String? 时 `cache[k] = nil` 是「删除这个键」而不是
            // 「存一个 nil」，所以必须用 updateValue 才能把「签不出来」如实缓存下来。
            cache.updateValue(part.uploadUrl, forKey: part.partNumber)
        }
    }

    func uploadURL(for partNumber: Int) async throws -> String? {
        if let cached = cache[partNumber] { return cached }
        // 服务端接受任意 from，直接从缺的那片开始签，一次就能覆盖到它
        let page: UploadPartsPage = try await session.request(
            UploadAPI.partURLs(sessionId: sessionId, from: partNumber)
        )
        for part in page.parts {
            cache.updateValue(part.uploadUrl, forKey: part.partNumber)
        }
        return cache[partNumber] ?? nil
    }

    /// 收到 403 时调用：丢掉这一片往后的缓存，下次访问会重新续签。
    func invalidate(from partNumber: Int) {
        for key in Array(cache.keys) where key >= partNumber {
            cache.removeValue(forKey: key)
        }
    }
}

// MARK: - 进度聚合

/// 把多片并发的字节数聚合成单调的整体进度。
actor UploadProgressTracker {
    private let totalBytes: Int64
    private let report: @MainActor @Sendable (Double) -> Void
    private var completedBytes: Int64 = 0        // 已确认完成的片
    private var inFlight: [Int: Int64] = [:]     // partNumber -> 本轮已发送字节
    private var lastReported: Double = 0

    init(totalBytes: Int64, report: @escaping @MainActor @Sendable (Double) -> Void) {
        self.totalBytes = totalBytes
        self.report = report
    }

    /// 续传时把服务端已有的片计入起点
    func seedCompleted(bytes: Int64) {
        completedBytes += bytes
        emit()
    }

    func update(part: Int, sent: Int64) {
        inFlight[part] = sent
        emit()
    }

    /// 重试前调用：这一片本轮已报的字节作废，否则重传会把进度算重
    func reset(part: Int) {
        inFlight[part] = 0
        emit()
    }

    func finish(part: Int, size: Int64) {
        inFlight[part] = nil
        completedBytes += size
        emit()
    }

    private func emit() {
        let sent = completedBytes + inFlight.values.reduce(0, +)
        let fraction = min(1, Double(sent) / Double(max(1, totalBytes)))
        // lastReported 同时承担单调性和节流：重试让某片回到 0 时进度条不倒退；
        // 每片 8 MiB 会触发上百次回调，不节流会把主线程刷满。
        guard fraction >= lastReported + 0.005 || fraction >= 1 else { return }
        lastReported = fraction
        Task { @MainActor [report] in report(fraction) }
    }
}

private final class PartProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let partNumber: Int
    private let tracker: UploadProgressTracker

    init(partNumber: Int, tracker: UploadProgressTracker) {
        self.partNumber = partNumber
        self.tracker = tracker
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        Task { [partNumber, tracker] in
            await tracker.update(part: partNumber, sent: totalBytesSent)
        }
    }
}
