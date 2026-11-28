import Foundation
import StolnkCore
import zlib

/// 本地压缩与解压缩引擎（基于系统内置 `libz`，无第三方依赖）。
///
/// - 压缩：生成标准 `.zip`（UTF-8 文件名标记、流式读写、媒体文件自动走 Store 免重复压缩、超 4GB 自动升级 ZIP64）。
/// - 解压：支持 `.zip`（含 Windows GB18030 中文文件名兼容与 Zip-Slip 路径穿越防护）、`.tar`、`.tar.gz` / `.tgz`、`.gz`。
nonisolated enum ArchiveService {
    enum ArchiveError: LocalizedError {
        case emptySelection
        case emptyArchive
        case unsupportedFormat
        case unsupportedMethod
        case encryptedArchive
        case corruptedArchive
        case compressionFailed

        var errorDescription: String? {
            switch self {
            case .emptySelection:
                return R.Strings.driveArchiveCompressFailed.localizedString()
            case .emptyArchive:
                return R.Strings.driveArchiveEmpty.localizedString()
            case .unsupportedFormat, .unsupportedMethod:
                return R.Strings.driveArchiveUnsupported.localizedString()
            case .encryptedArchive:
                return R.Strings.driveArchiveEncrypted.localizedString()
            case .corruptedArchive:
                return R.Strings.driveArchiveCorrupted.localizedString()
            case .compressionFailed:
                return R.Strings.driveArchiveCompressFailed.localizedString()
            }
        }
    }

    private enum Format {
        case zip
        case tar
        case tarGz
        case gz

        init?(fileName: String) {
            let lower = fileName.lowercased()
            if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
                self = .tarGz
            } else if lower.hasSuffix(".zip") {
                self = .zip
            } else if lower.hasSuffix(".tar") {
                self = .tar
            } else if lower.hasSuffix(".gz") {
                self = .gz
            } else {
                return nil
            }
        }
    }

    private static let chunkSize = 64 * 1024

    /// 已经高度压缩的媒体或归档扩展名：直接 Store（method 0），省去无意义的 CPU 时间。
    private static let storeExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "webp",
        "mp4", "mov", "m4v", "mkv", "avi",
        "mp3", "m4a", "aac", "flac",
        "zip", "gz", "tgz", "7z", "rar", "xz", "bz2"
    ]

    static func canExtract(fileName: String) -> Bool {
        Format(fileName: fileName) != nil
    }

    static func baseName(forArchive fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".tar.gz") {
            let trimmed = String(fileName.dropLast(".tar.gz".count))
            return trimmed.isEmpty ? "Archive" : trimmed
        }
        let stripped = (fileName as NSString).deletingPathExtension
        return stripped.isEmpty ? "Archive" : stripped
    }

    // MARK: - 压缩 (.zip)

    private struct SourceEntry {
        let relativePath: String
        let fileURL: URL?
        let isDirectory: Bool
        let uncompressedSize: UInt64
        let modifiedAt: Date
    }

    private struct CentralRecord {
        let nameBytes: Data
        let method: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isDirectory: Bool
    }

    static func compress(sources: [URL], to destinationZip: URL) throws {
        let fm = FileManager.default
        let entries = try collectEntries(from: sources, fileManager: fm)
        guard !entries.isEmpty else { throw ArchiveError.emptySelection }

        let parentDir = destinationZip.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tempURL = parentDir.appendingPathComponent(".\(UUID().uuidString).zip.part")
        fm.createFile(atPath: tempURL.path, contents: nil)
        defer { try? fm.removeItem(at: tempURL) }

        let outHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? outHandle.close() }

        var centralRecords: [CentralRecord] = []
        centralRecords.reserveCapacity(entries.count)

        for entry in entries {
            let localOffset = try outHandle.offset()
            let pathString = entry.isDirectory
                ? (entry.relativePath.hasSuffix("/") ? entry.relativePath : entry.relativePath + "/")
                : entry.relativePath
            let nameBytes = Data(pathString.utf8)
            let (dosTime, dosDate) = dosDateTime(from: entry.modifiedAt)

            let ext = URL(fileURLWithPath: entry.relativePath).pathExtension.lowercased()
            let method: UInt16 = (entry.isDirectory || entry.uncompressedSize == 0 || storeExtensions.contains(ext))
                ? 0 : 8
            let needsLocalZip64 = entry.uncompressedSize >= 0xFFFF_FFFF
            let versionNeeded: UInt16 = needsLocalZip64 ? 45 : 20
            let flags: UInt16 = 0x0800 // Bit 11: UTF-8 filename

            var localHeader = Data(capacity: 30 + nameBytes.count + (needsLocalZip64 ? 20 : 0))
            localHeader.appendUInt32LE(0x0403_4B50)
            localHeader.appendUInt16LE(versionNeeded)
            localHeader.appendUInt16LE(flags)
            localHeader.appendUInt16LE(method)
            localHeader.appendUInt16LE(dosTime)
            localHeader.appendUInt16LE(dosDate)
            localHeader.appendUInt32LE(0) // crc32 placeholder
            localHeader.appendUInt32LE(needsLocalZip64 ? 0xFFFF_FFFF : 0) // compressed placeholder
            localHeader.appendUInt32LE(needsLocalZip64 ? 0xFFFF_FFFF : UInt32(entry.uncompressedSize))
            localHeader.appendUInt16LE(UInt16(nameBytes.count))
            localHeader.appendUInt16LE(needsLocalZip64 ? 20 : 0)
            localHeader.append(nameBytes)
            if needsLocalZip64 {
                localHeader.appendUInt16LE(0x0001)
                localHeader.appendUInt16LE(16)
                localHeader.appendUInt64LE(entry.uncompressedSize)
                localHeader.appendUInt64LE(0) // compressed placeholder
            }
            try outHandle.write(contentsOf: localHeader)

            var crc: UInt32 = 0
            var compressedSize: UInt64 = 0
            var actualUncompressed: UInt64 = 0

            if let fileURL = entry.fileURL, !entry.isDirectory {
                if method == 0 {
                    (crc, compressedSize, actualUncompressed) = try writeStored(from: fileURL, to: outHandle)
                } else {
                    (crc, compressedSize, actualUncompressed) = try writeDeflated(from: fileURL, to: outHandle)
                }

                let endOffset = try outHandle.offset()
                try outHandle.seek(toOffset: localOffset + 14)
                var patch = Data(capacity: 12)
                patch.appendUInt32LE(crc)
                if needsLocalZip64 {
                    patch.appendUInt32LE(0xFFFF_FFFF)
                    patch.appendUInt32LE(0xFFFF_FFFF)
                    try outHandle.write(contentsOf: patch)
                    let extraOffset = localOffset + 30 + UInt64(nameBytes.count) + 4
                    try outHandle.seek(toOffset: extraOffset)
                    var zip64Patch = Data(capacity: 16)
                    zip64Patch.appendUInt64LE(actualUncompressed)
                    zip64Patch.appendUInt64LE(compressedSize)
                    try outHandle.write(contentsOf: zip64Patch)
                } else if compressedSize >= 0xFFFF_FFFF || actualUncompressed >= 0xFFFF_FFFF {
                    throw ArchiveError.compressionFailed
                } else {
                    patch.appendUInt32LE(UInt32(compressedSize))
                    patch.appendUInt32LE(UInt32(actualUncompressed))
                    try outHandle.write(contentsOf: patch)
                }
                try outHandle.seek(toOffset: endOffset)
            }

            centralRecords.append(CentralRecord(
                nameBytes: nameBytes,
                method: method,
                dosTime: dosTime,
                dosDate: dosDate,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: actualUncompressed,
                localHeaderOffset: localOffset,
                isDirectory: entry.isDirectory
            ))
        }

        let cdStartOffset = try outHandle.offset()
        for record in centralRecords {
            let zip64Uncomp = record.uncompressedSize >= 0xFFFF_FFFF
            let zip64Comp = record.compressedSize >= 0xFFFF_FFFF
            let zip64Offset = record.localHeaderOffset >= 0xFFFF_FFFF
            var extra = Data()
            if zip64Uncomp || zip64Comp || zip64Offset {
                var payload = Data()
                if zip64Uncomp { payload.appendUInt64LE(record.uncompressedSize) }
                if zip64Comp { payload.appendUInt64LE(record.compressedSize) }
                if zip64Offset { payload.appendUInt64LE(record.localHeaderOffset) }
                extra.appendUInt16LE(0x0001)
                extra.appendUInt16LE(UInt16(payload.count))
                extra.append(payload)
            }

            let versionNeeded: UInt16 = extra.isEmpty ? 20 : 45
            let externalAttr: UInt32 = record.isDirectory ? 0x41ED_0010 : 0x81A4_0000

            var cd = Data(capacity: 46 + record.nameBytes.count + extra.count)
            cd.appendUInt32LE(0x0201_4B50)
            cd.appendUInt16LE(0x031E) // Unix + PKZIP 3.0
            cd.appendUInt16LE(versionNeeded)
            cd.appendUInt16LE(0x0800) // UTF-8
            cd.appendUInt16LE(record.method)
            cd.appendUInt16LE(record.dosTime)
            cd.appendUInt16LE(record.dosDate)
            cd.appendUInt32LE(record.crc32)
            cd.appendUInt32LE(zip64Comp ? 0xFFFF_FFFF : UInt32(record.compressedSize))
            cd.appendUInt32LE(zip64Uncomp ? 0xFFFF_FFFF : UInt32(record.uncompressedSize))
            cd.appendUInt16LE(UInt16(record.nameBytes.count))
            cd.appendUInt16LE(UInt16(extra.count))
            cd.appendUInt16LE(0) // comment length
            cd.appendUInt16LE(0) // disk number
            cd.appendUInt16LE(0) // internal attr
            cd.appendUInt32LE(externalAttr)
            cd.appendUInt32LE(zip64Offset ? 0xFFFF_FFFF : UInt32(record.localHeaderOffset))
            cd.append(record.nameBytes)
            cd.append(extra)
            try outHandle.write(contentsOf: cd)
        }

        let cdEndOffset = try outHandle.offset()
        let cdSize = cdEndOffset - cdStartOffset
        let count = UInt64(centralRecords.count)
        let needsZip64EOCD = count >= 0xFFFF || cdSize >= 0xFFFF_FFFF || cdStartOffset >= 0xFFFF_FFFF

        if needsZip64EOCD {
            var zip64EOCD = Data(capacity: 56)
            zip64EOCD.appendUInt32LE(0x0606_4B50)
            zip64EOCD.appendUInt64LE(44)
            zip64EOCD.appendUInt16LE(45)
            zip64EOCD.appendUInt16LE(45)
            zip64EOCD.appendUInt32LE(0)
            zip64EOCD.appendUInt32LE(0)
            zip64EOCD.appendUInt64LE(count)
            zip64EOCD.appendUInt64LE(count)
            zip64EOCD.appendUInt64LE(cdSize)
            zip64EOCD.appendUInt64LE(cdStartOffset)
            try outHandle.write(contentsOf: zip64EOCD)

            var locator = Data(capacity: 20)
            locator.appendUInt32LE(0x0706_4B50)
            locator.appendUInt32LE(0)
            locator.appendUInt64LE(cdEndOffset)
            locator.appendUInt32LE(1)
            try outHandle.write(contentsOf: locator)
        }

        var eocd = Data(capacity: 22)
        eocd.appendUInt32LE(0x0605_4B50)
        eocd.appendUInt16LE(0)
        eocd.appendUInt16LE(0)
        eocd.appendUInt16LE(count >= 0xFFFF ? 0xFFFF : UInt16(count))
        eocd.appendUInt16LE(count >= 0xFFFF ? 0xFFFF : UInt16(count))
        eocd.appendUInt32LE(cdSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdSize))
        eocd.appendUInt32LE(cdStartOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdStartOffset))
        eocd.appendUInt16LE(0)
        try outHandle.write(contentsOf: eocd)
        try outHandle.close()

        try fm.moveItem(at: tempURL, to: destinationZip)
    }

    private static func collectEntries(from sources: [URL], fileManager fm: FileManager) throws -> [SourceEntry] {
        var entries: [SourceEntry] = []
        var usedTopNames: Set<String> = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        for source in sources {
            let values = try source.resourceValues(forKeys: Set(keys))
            var topName = source.lastPathComponent
            if usedTopNames.contains(topName) {
                let ext = (topName as NSString).pathExtension
                let stem = (topName as NSString).deletingPathExtension
                var index = 2
                while usedTopNames.contains(topName) {
                    topName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
                    index += 1
                }
            }
            usedTopNames.insert(topName)

            if values.isDirectory == true {
                entries.append(SourceEntry(
                    relativePath: topName,
                    fileURL: nil,
                    isDirectory: true,
                    uncompressedSize: 0,
                    modifiedAt: values.contentModificationDate ?? Date()
                ))
                let basePath = source.resolvingSymlinksInPath().standardizedFileURL.path
                if let enumerator = fm.enumerator(
                    at: source,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) {
                    for case let childURL as URL in enumerator {
                        guard !childURL.lastPathComponent.hasPrefix(".") else { continue }
                        let childPath = childURL.resolvingSymlinksInPath().standardizedFileURL.path
                        guard childPath.hasPrefix(basePath + "/") else { continue }
                        let suffix = String(childPath.dropFirst(basePath.count + 1))
                        let rel = "\(topName)/\(suffix)"
                        let childValues = try childURL.resourceValues(forKeys: Set(keys))
                        if childValues.isDirectory == true {
                            entries.append(SourceEntry(
                                relativePath: rel,
                                fileURL: nil,
                                isDirectory: true,
                                uncompressedSize: 0,
                                modifiedAt: childValues.contentModificationDate ?? Date()
                            ))
                        } else if childValues.isRegularFile == true {
                            entries.append(SourceEntry(
                                relativePath: rel,
                                fileURL: childURL,
                                isDirectory: false,
                                uncompressedSize: UInt64(max(0, childValues.fileSize ?? 0)),
                                modifiedAt: childValues.contentModificationDate ?? Date()
                            ))
                        }
                    }
                }
            } else if values.isRegularFile == true {
                entries.append(SourceEntry(
                    relativePath: topName,
                    fileURL: source,
                    isDirectory: false,
                    uncompressedSize: UInt64(max(0, values.fileSize ?? 0)),
                    modifiedAt: values.contentModificationDate ?? Date()
                ))
            }
        }
        return entries
    }

    private static func writeStored(
        from sourceURL: URL,
        to outHandle: FileHandle
    ) throws -> (crc: UInt32, compressed: UInt64, uncompressed: UInt64) {
        let inHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? inHandle.close() }

        var crc = zlib.crc32(0, nil, 0)
        var total: UInt64 = 0

        while let chunk = try inHandle.read(upToCount: chunkSize), !chunk.isEmpty {
            crc = chunk.withUnsafeBytes { raw in
                zlib.crc32(crc, raw.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count))
            }
            try outHandle.write(contentsOf: chunk)
            total += UInt64(chunk.count)
        }
        return (UInt32(crc & 0xFFFF_FFFF), total, total)
    }

    private static func writeDeflated(
        from sourceURL: URL,
        to outHandle: FileHandle
    ) throws -> (crc: UInt32, compressed: UInt64, uncompressed: UInt64) {
        let inHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? inHandle.close() }

        var stream = z_stream()
        let initCode = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initCode == Z_OK else { throw ArchiveError.compressionFailed }
        defer { deflateEnd(&stream) }

        var crc = zlib.crc32(0, nil, 0)
        var uncompressed: UInt64 = 0
        var compressed: UInt64 = 0
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        let outCapacity = outBuffer.count

        while true {
            let chunk = try inHandle.read(upToCount: chunkSize) ?? Data()
            let isEOF = chunk.isEmpty
            if !isEOF {
                crc = chunk.withUnsafeBytes { raw in
                    zlib.crc32(crc, raw.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count))
                }
                uncompressed += UInt64(chunk.count)
            }

            try chunk.withUnsafeBytes { inRaw in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inRaw.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(chunk.count)

                repeat {
                    let produced: Int = try outBuffer.withUnsafeMutableBufferPointer { outBuf in
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = uInt(outCapacity)
                        let status = deflate(&stream, isEOF ? Z_FINISH : Z_NO_FLUSH)
                        guard status != Z_STREAM_ERROR else { throw ArchiveError.compressionFailed }
                        return outCapacity - Int(stream.avail_out)
                    }
                    if produced > 0 {
                        try outHandle.write(contentsOf: outBuffer.prefix(produced))
                        compressed += UInt64(produced)
                    }
                } while stream.avail_out == 0
            }

            if isEOF { break }
        }

        return (UInt32(crc & 0xFFFF_FFFF), compressed, uncompressed)
    }

    // MARK: - 解压 (.zip / .tar / .tar.gz / .gz)

    static func extract(archiveAt sourceURL: URL, into destinationRoot: URL) throws {
        guard let format = Format(fileName: sourceURL.lastPathComponent) else {
            throw ArchiveError.unsupportedFormat
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        switch format {
        case .zip:
            try extractZip(at: sourceURL, into: destinationRoot, fileManager: fm)
        case .tar:
            try extractTar(at: sourceURL, into: destinationRoot, fileManager: fm)
        case .tarGz:
            let tempTar = fm.temporaryDirectory
                .appendingPathComponent("stolnk-untar-\(UUID().uuidString).tar")
            defer { try? fm.removeItem(at: tempTar) }
            try decompressGzip(at: sourceURL, to: tempTar)
            try extractTar(at: tempTar, into: destinationRoot, fileManager: fm)
        case .gz:
            let outputName = FileNameSanitizer.sanitize(baseName(forArchive: sourceURL.lastPathComponent))
            let target = destinationRoot.appendingPathComponent(outputName)
            try decompressGzip(at: sourceURL, to: target)
        }
    }

    // MARK: - ZIP 解压

    private static func extractZip(
        at sourceURL: URL,
        into destinationRoot: URL,
        fileManager fm: FileManager
    ) throws {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ArchiveError.corruptedArchive }

        let maxTail = min(fileSize, 65_557)
        let tailOffset = fileSize - maxTail
        try handle.seek(toOffset: tailOffset)
        guard let tail = try handle.read(upToCount: Int(maxTail)) else {
            throw ArchiveError.corruptedArchive
        }

        var eocdPosInTail: Int?
        if tail.count >= 22 {
            for i in stride(from: tail.count - 22, through: 0, by: -1) {
                if tail.readUInt32LE(at: i) == 0x0605_4B50 {
                    let commentLen = Int(tail.readUInt16LE(at: i + 20))
                    if i + 22 + commentLen == tail.count {
                        eocdPosInTail = i
                        break
                    }
                }
            }
        }
        guard let eocdIdx = eocdPosInTail else { throw ArchiveError.corruptedArchive }

        var totalEntries = UInt64(tail.readUInt16LE(at: eocdIdx + 10))
        var cdSize = UInt64(tail.readUInt32LE(at: eocdIdx + 12))
        var cdOffset = UInt64(tail.readUInt32LE(at: eocdIdx + 16))

        // 检查 ZIP64 EOCD Locator (紧挨在 EOCD 前 20 字节)
        let eocdAbsOffset = tailOffset + UInt64(eocdIdx)
        if eocdAbsOffset >= 20 {
            try handle.seek(toOffset: eocdAbsOffset - 20)
            if let loc = try handle.read(upToCount: 20),
               loc.count == 20,
               loc.readUInt32LE(at: 0) == 0x0706_4B50 {
                let zip64Offset = loc.readUInt64LE(at: 8)
                try handle.seek(toOffset: zip64Offset)
                if let z64 = try handle.read(upToCount: 56),
                   z64.count == 56,
                   z64.readUInt32LE(at: 0) == 0x0606_4B50 {
                    totalEntries = z64.readUInt64LE(at: 32)
                    cdSize = z64.readUInt64LE(at: 40)
                    cdOffset = z64.readUInt64LE(at: 48)
                }
            }
        }

        guard cdOffset + cdSize <= fileSize else { throw ArchiveError.corruptedArchive }
        try handle.seek(toOffset: cdOffset)
        let cdData = try handle.read(upToCount: Int(cdSize)) ?? Data()
        guard cdData.count == Int(cdSize) else { throw ArchiveError.corruptedArchive }

        var cursor = 0
        var parsedEntries: UInt64 = 0
        while cursor + 46 <= cdData.count && cdData.readUInt32LE(at: cursor) == 0x0201_4B50 {
            parsedEntries += 1
            let madeBy = cdData[cursor + 5]
            let flags = cdData.readUInt16LE(at: cursor + 8)
            if (flags & 0x0001) != 0 {
                throw ArchiveError.encryptedArchive
            }

            let method = cdData.readUInt16LE(at: cursor + 10)
            let expectedCRC = cdData.readUInt32LE(at: cursor + 16)
            var compSize = UInt64(cdData.readUInt32LE(at: cursor + 20))
            var uncompSize = UInt64(cdData.readUInt32LE(at: cursor + 24))
            let nameLen = Int(cdData.readUInt16LE(at: cursor + 28))
            let extraLen = Int(cdData.readUInt16LE(at: cursor + 30))
            let commentLen = Int(cdData.readUInt16LE(at: cursor + 32))
            let externalAttr = cdData.readUInt32LE(at: cursor + 38)
            var localOffset = UInt64(cdData.readUInt32LE(at: cursor + 42))

            let headerEnd = cursor + 46 + nameLen + extraLen + commentLen
            guard headerEnd <= cdData.count else { throw ArchiveError.corruptedArchive }

            let nameData = cdData.subdata(in: (cursor + 46)..<(cursor + 46 + nameLen))
            let extraData = cdData.subdata(in: (cursor + 46 + nameLen)..<(cursor + 46 + nameLen + extraLen))
            cursor = headerEnd

            if uncompSize == 0xFFFF_FFFF || compSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                parseZip64Extra(
                    extraData,
                    uncompressedSize: &uncompSize,
                    compressedSize: &compSize,
                    localHeaderOffset: &localOffset
                )
            }

            let rawPath = decodeZipName(nameData)
            // 仅在 Unix / macOS 生成的条目上按 POSIX 模式跳过符号链接，防止软链逃逸沙盒。
            if madeBy == 3 || madeBy == 19 {
                let unixMode = (externalAttr >> 16) & 0xF000
                if unixMode == 0xA000 { continue }
            }

            let isDir = rawPath.hasSuffix("/") || rawPath.hasSuffix("\\") || ((externalAttr & 0x10) != 0 && uncompSize == 0)
            guard let targetURL = safeDestinationURL(for: rawPath, inside: destinationRoot) else {
                continue
            }

            if isDir {
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                continue
            }

            guard localOffset + 30 <= fileSize else { throw ArchiveError.corruptedArchive }
            try handle.seek(toOffset: localOffset)
            guard let localHdr = try handle.read(upToCount: 30),
                  localHdr.count == 30,
                  localHdr.readUInt32LE(at: 0) == 0x0403_4B50 else {
                throw ArchiveError.corruptedArchive
            }
            let localNameLen = UInt64(localHdr.readUInt16LE(at: 26))
            let localExtraLen = UInt64(localHdr.readUInt16LE(at: 28))
            let dataStart = localOffset + 30 + localNameLen + localExtraLen
            guard dataStart + compSize <= fileSize else { throw ArchiveError.corruptedArchive }

            try fm.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            fm.createFile(atPath: targetURL.path, contents: nil)
            let outHandle = try FileHandle(forWritingTo: targetURL)
            defer { try? outHandle.close() }

            try handle.seek(toOffset: dataStart)
            let actualCRC: UInt32
            switch method {
            case 0:
                actualCRC = try copyBoundedStored(from: handle, byteCount: compSize, to: outHandle)
            case 8:
                actualCRC = try inflateBoundedRaw(from: handle, compressedCount: compSize, to: outHandle)
            default:
                throw ArchiveError.unsupportedMethod
            }

            if actualCRC != expectedCRC {
                throw ArchiveError.corruptedArchive
            }
        }
        if totalEntries > 0 && parsedEntries == 0 {
            throw ArchiveError.corruptedArchive
        }
    }

    private static func parseZip64Extra(
        _ extra: Data,
        uncompressedSize: inout UInt64,
        compressedSize: inout UInt64,
        localHeaderOffset: inout UInt64
    ) {
        var pos = 0
        while pos + 4 <= extra.count {
            let tag = extra.readUInt16LE(at: pos)
            let size = Int(extra.readUInt16LE(at: pos + 2))
            pos += 4
            guard pos + size <= extra.count else { return }
            if tag == 0x0001 {
                var fieldPos = pos
                if uncompressedSize == 0xFFFF_FFFF, fieldPos + 8 <= pos + size {
                    uncompressedSize = extra.readUInt64LE(at: fieldPos)
                    fieldPos += 8
                }
                if compressedSize == 0xFFFF_FFFF, fieldPos + 8 <= pos + size {
                    compressedSize = extra.readUInt64LE(at: fieldPos)
                    fieldPos += 8
                }
                if localHeaderOffset == 0xFFFF_FFFF, fieldPos + 8 <= pos + size {
                    localHeaderOffset = extra.readUInt64LE(at: fieldPos)
                }
                return
            }
            pos += size
        }
    }

    private static func decodeZipName(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let decoded = String(data: data, encoding: gb18030) {
            return decoded
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func copyBoundedStored(
        from inHandle: FileHandle,
        byteCount: UInt64,
        to outHandle: FileHandle
    ) throws -> UInt32 {
        var remaining = byteCount
        var crc = zlib.crc32(0, nil, 0)
        while remaining > 0 {
            let toRead = Int(min(UInt64(chunkSize), remaining))
            guard let chunk = try inHandle.read(upToCount: toRead), !chunk.isEmpty else {
                throw ArchiveError.corruptedArchive
            }
            crc = chunk.withUnsafeBytes { raw in
                zlib.crc32(crc, raw.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count))
            }
            try outHandle.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        return UInt32(crc & 0xFFFF_FFFF)
    }

    private static func inflateBoundedRaw(
        from inHandle: FileHandle,
        compressedCount: UInt64,
        to outHandle: FileHandle
    ) throws -> UInt32 {
        if compressedCount == 0 { return 0 }

        var stream = z_stream()
        let initCode = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initCode == Z_OK else { throw ArchiveError.corruptedArchive }
        defer { inflateEnd(&stream) }

        var remaining = compressedCount
        var crc = zlib.crc32(0, nil, 0)
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        let outCapacity = outBuffer.count
        var reachedStreamEnd = false

        while remaining > 0 && !reachedStreamEnd {
            let toRead = Int(min(UInt64(chunkSize), remaining))
            guard let chunk = try inHandle.read(upToCount: toRead), !chunk.isEmpty else {
                throw ArchiveError.corruptedArchive
            }
            remaining -= UInt64(chunk.count)

            try chunk.withUnsafeBytes { inRaw in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inRaw.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(chunk.count)

                repeat {
                    var status: Int32 = Z_OK
                    let produced: Int = outBuffer.withUnsafeMutableBufferPointer { outBuf in
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = uInt(outCapacity)
                        status = inflate(&stream, Z_NO_FLUSH)
                        return outCapacity - Int(stream.avail_out)
                    }
                    if status == Z_NEED_DICT || status == Z_DATA_ERROR || status == Z_MEM_ERROR || status == Z_STREAM_ERROR {
                        throw ArchiveError.corruptedArchive
                    }
                    if produced > 0 {
                        crc = outBuffer.withUnsafeBufferPointer { buf in
                            zlib.crc32(crc, buf.baseAddress, uInt(produced))
                        }
                        try outHandle.write(contentsOf: outBuffer.prefix(produced))
                    }
                    if status == Z_STREAM_END {
                        reachedStreamEnd = true
                        break
                    }
                } while stream.avail_out == 0
            }
        }

        return UInt32(crc & 0xFFFF_FFFF)
    }

    // MARK: - GZIP 与 TAR 解压

    private static func decompressGzip(at sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        fm.createFile(atPath: destinationURL.path, contents: nil)

        let inHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? inHandle.close() }
        let outHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? outHandle.close() }

        var stream = z_stream()
        let initCode = inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initCode == Z_OK else { throw ArchiveError.corruptedArchive }
        defer { inflateEnd(&stream) }

        var outBuffer = [UInt8](repeating: 0, count: chunkSize)
        let outCapacity = outBuffer.count

        while let chunk = try inHandle.read(upToCount: chunkSize), !chunk.isEmpty {
            try chunk.withUnsafeBytes { inRaw in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: inRaw.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(chunk.count)

                repeat {
                    var status: Int32 = Z_OK
                    let produced: Int = outBuffer.withUnsafeMutableBufferPointer { outBuf in
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = uInt(outCapacity)
                        status = inflate(&stream, Z_NO_FLUSH)
                        return outCapacity - Int(stream.avail_out)
                    }
                    if status == Z_NEED_DICT || status == Z_DATA_ERROR || status == Z_MEM_ERROR || status == Z_STREAM_ERROR {
                        throw ArchiveError.corruptedArchive
                    }
                    if produced > 0 {
                        try outHandle.write(contentsOf: outBuffer.prefix(produced))
                    }
                    if status == Z_STREAM_END {
                        if stream.avail_in > 0 {
                            guard inflateReset(&stream) == Z_OK else {
                                throw ArchiveError.corruptedArchive
                            }
                            continue
                        }
                        break
                    }
                } while stream.avail_out == 0
            }
        }
    }

    private static func extractTar(
        at sourceURL: URL,
        into destinationRoot: URL,
        fileManager fm: FileManager
    ) throws {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        var pendingLongPath: String?

        while let block = try handle.read(upToCount: 512), !block.isEmpty {
            guard block.count == 512 else { throw ArchiveError.corruptedArchive }
            if block.allSatisfy({ $0 == 0 }) { break }

            let size = parseTarSize(block.subdata(in: 124..<136))
            let typeFlag = block[156]
            let paddedSize = (size + 511) & ~511

            if typeFlag == UInt8(ascii: "L") {
                if let nameBytes = try handle.read(upToCount: Int(paddedSize)) {
                    let trimmed = nameBytes.prefix(Int(size)).prefix { $0 != 0 }
                    pendingLongPath = String(data: Data(trimmed), encoding: .utf8)
                }
                continue
            }

            if typeFlag == UInt8(ascii: "x") {
                if let paxBytes = try handle.read(upToCount: Int(paddedSize)),
                   let paxText = String(data: paxBytes.prefix(Int(size)), encoding: .utf8),
                   let paxPath = parsePaxPath(paxText) {
                    pendingLongPath = paxPath
                }
                continue
            }

            let rawPath: String
            if let override = pendingLongPath {
                rawPath = override
                pendingLongPath = nil
            } else {
                let namePart = tarNullTerminatedString(block.subdata(in: 0..<100))
                let prefixPart = tarNullTerminatedString(block.subdata(in: 345..<500))
                rawPath = prefixPart.isEmpty ? namePart : "\(prefixPart)/\(namePart)"
            }

            let isDirectory = typeFlag == UInt8(ascii: "5") || rawPath.hasSuffix("/")
            let isRegularFile = typeFlag == 0 || typeFlag == UInt8(ascii: "0") || typeFlag == UInt8(ascii: "7")

            if isDirectory {
                if let targetURL = safeDestinationURL(for: rawPath, inside: destinationRoot) {
                    try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                }
                if paddedSize > 0 {
                    let cur = try handle.offset()
                    try handle.seek(toOffset: cur + paddedSize)
                }
            } else if isRegularFile {
                if let targetURL = safeDestinationURL(for: rawPath, inside: destinationRoot) {
                    try fm.createDirectory(
                        at: targetURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    fm.createFile(atPath: targetURL.path, contents: nil)
                    let outHandle = try FileHandle(forWritingTo: targetURL)
                    defer { try? outHandle.close() }
                    _ = try copyBoundedStored(from: handle, byteCount: size, to: outHandle)
                    let remainder = paddedSize - size
                    if remainder > 0 {
                        let cur = try handle.offset()
                        try handle.seek(toOffset: cur + remainder)
                    }
                } else if paddedSize > 0 {
                    let cur = try handle.offset()
                    try handle.seek(toOffset: cur + paddedSize)
                }
            } else if paddedSize > 0 {
                let cur = try handle.offset()
                try handle.seek(toOffset: cur + paddedSize)
            }
        }
    }

    private static func parseTarSize(_ field: Data) -> UInt64 {
        guard let first = field.first else { return 0 }
        if (first & 0x80) != 0 {
            var value: UInt64 = 0
            for byte in field.dropFirst().suffix(8) {
                value = (value << 8) | UInt64(byte)
            }
            return value
        }
        let text = tarNullTerminatedString(field).trimmingCharacters(in: .whitespaces)
        return UInt64(text, radix: 8) ?? 0
    }

    private static func tarNullTerminatedString(_ data: Data) -> String {
        let slice = data.prefix { $0 != 0 }
        return decodeZipName(Data(slice))
    }

    private static func parsePaxPath(_ pax: String) -> String? {
        var index = pax.startIndex
        while index < pax.endIndex {
            guard let spaceIdx = pax[index...].firstIndex(of: " "),
                  let length = Int(pax[index..<spaceIdx]),
                  length > 0 else { break }
            let recordEnd = pax.utf8.index(index, offsetBy: length, limitedBy: pax.utf8.endIndex)
                .flatMap { String.Index($0, within: pax) } ?? pax.endIndex
            let bodyStart = pax.index(after: spaceIdx)
            if bodyStart < recordEnd {
                var record = String(pax[bodyStart..<recordEnd])
                if record.hasSuffix("\n") { record.removeLast() }
                if record.hasPrefix("path=") {
                    return String(record.dropFirst("path=".count))
                }
            }
            index = recordEnd
        }
        return nil
    }

    // MARK: - 安全路径与时间戳

    /// 过滤 `__MACOSX`、AppleDouble `._*` 与 `..` 路径穿越，确保目标严格位于根目录内。
    private static func safeDestinationURL(for rawPath: String, inside root: URL) -> URL? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        let rawComponents = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !rawComponents.isEmpty else { return nil }

        var cleanComponents: [String] = []
        for piece in rawComponents {
            let str = String(piece)
            if str == "." { continue }
            if str == ".." || str == "__MACOSX" || str == ".DS_Store" || str.hasPrefix("._") {
                return nil
            }
            let safe = FileNameSanitizer.sanitize(str)
            guard !safe.isEmpty, safe != ".", safe != ".." else { return nil }
            cleanComponents.append(safe)
        }
        guard !cleanComponents.isEmpty else { return nil }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var target = resolvedRoot
        for comp in cleanComponents {
            target.appendPathComponent(comp)
        }
        let rootPath = resolvedRoot.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else { return nil }
        return target
    }

    private static func dosDateTime(from date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, comps.year ?? 1980))
        let month = max(1, min(12, comps.month ?? 1))
        let day = max(1, min(31, comps.day ?? 1))
        let hour = max(0, min(23, comps.hour ?? 0))
        let minute = max(0, min(59, comps.minute ?? 0))
        let second = max(0, min(59, comps.second ?? 0))

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }
}

private nonisolated extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[startIndex + offset])
        let b1 = UInt16(self[startIndex + offset + 1]) << 8
        return b0 | b1
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[startIndex + offset])
        let b1 = UInt32(self[startIndex + offset + 1]) << 8
        let b2 = UInt32(self[startIndex + offset + 2]) << 16
        let b3 = UInt32(self[startIndex + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<8 {
            result |= UInt64(self[startIndex + offset + i]) << (i * 8)
        }
        return result
    }
}
