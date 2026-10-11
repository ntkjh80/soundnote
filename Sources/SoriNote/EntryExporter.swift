import Foundation

enum ExportFormat: CaseIterable, Hashable {
    case bundle, audio, transcript, markdown

    var title: String {
        switch self {
        case .bundle: return "녹음 + 전사문 함께 저장…"
        case .audio: return "녹음 파일만 저장…"
        case .transcript: return "전사문·원문만 저장…"
        case .markdown: return "요약 포함 Markdown 저장…"
        }
    }

    func isAvailable(for entry: Entry?) -> Bool {
        guard let entry else { return false }
        let hasText = !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch self {
        case .bundle: return !entry.audio_path.isEmpty && hasText
        case .audio: return !entry.audio_path.isEmpty
        case .transcript: return hasText
        case .markdown: return true
        }
    }

    func fileExtension(for entry: Entry) -> String {
        switch self {
        case .audio: return URL(fileURLWithPath: entry.audio_path).pathExtension
        case .transcript: return "txt"
        case .markdown: return "md"
        case .bundle: return ""
        }
    }
}

/// 녹음은 재인코딩하지 않고 복사합니다. 가변 상태는 잠금으로 보호하는 취소 표시뿐입니다.
/// 파일 작업은 백그라운드에서 실행하며, UI와 워커의 저장 구조에 의존하지 않습니다.
final class EntryExportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    private func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    static func safeName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let clean = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        // 한글·이모지를 중간 바이트에서 자르지 않습니다. 확장자와 중복 번호 공간도 남깁니다.
        var result = ""
        for character in clean {
            guard result.utf8.count + String(character).utf8.count <= 140 else { break }
            result.append(character)
        }
        return result.isEmpty ? "제목 없는 기록" : result
    }

    static func transcript(_ entry: Entry) -> String {
        // 화면의 최신 원문이 기준입니다. 수동 수정 뒤 남아 있을 수 있는 구간으로 재생성하지 않습니다.
        "\(entry.title)\n작성 시각: \(entry.created)\n\n\(entry.text)\n"
    }

    static func markdown(_ entry: Entry) -> String {
        "# \(entry.title)\n\n작성 시각: \(entry.created)\n\n## AI 요약\n\n"
            + (entry.summary.isEmpty ? "아직 요약하지 않았습니다." : entry.summary)
            + "\n\n## 원문\n\n\(entry.text)\n"
    }

    /// bundle의 destination은 부모 폴더, 나머지는 사용자가 선택한 최종 파일 경로입니다.
    /// 기존 파일 교체는 저장 대화상자에서 사용자가 확인한 경우에만 허용합니다.
    func write(_ format: ExportFormat, entry: Entry, destination: URL,
               protectedDirectory: URL, replaceExisting: Bool = false,
               copied: (Int64) -> Void = { _ in }) throws -> URL {
        try checkCancellation()
        guard format.isAvailable(for: entry) else {
            throw AppFailure(message: "저장할 녹음이나 전사문이 없습니다. 먼저 녹음을 완료하고 문자 변환을 실행하세요.")
        }
        let target = destination.standardizedFileURL
        let parent = format == .bundle ? target : target.deletingLastPathComponent()
        let protected = protectedDirectory.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        // 새 파일은 아직 존재하지 않아 링크 해석이 끝까지 되지 않을 수 있습니다.
        // 실제로 존재하는 부모 폴더도 별도로 확인하며, macOS의 대소문자 무시 경로를 보수적으로 보호합니다.
        let resolvedPaths = [target, parent].map { $0.resolvingSymlinksInPath().path.lowercased() }
        guard resolvedPaths.allSatisfy({ $0 != protected && !$0.hasPrefix(protected + "/") }) else {
            throw AppFailure(message: "앱 데이터가 덮어써지지 않도록 데이터 폴더 밖의 저장 위치를 선택하세요.")
        }
        let manager = FileManager.default
        // 같은 볼륨에 임시 결과를 만듭니다. 실패·취소 시 자신이 만든 임시 폴더만 지웁니다.
        let staging = parent.appendingPathComponent(".sorinote-export-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let name = Self.safeName(entry.title)
        if format == .bundle {
            let source = URL(fileURLWithPath: entry.audio_path)
            let audioURL = source.pathExtension.isEmpty ? staging.appendingPathComponent("녹음")
                : staging.appendingPathComponent("녹음").appendingPathExtension(source.pathExtension)
            try copyAudio(from: source, to: audioURL, copied: copied)
            try writeText(Self.transcript(entry), to: staging.appendingPathComponent("전사문.txt"))
            try writeText(Self.markdown(entry), to: staging.appendingPathComponent("회의록.md"))
            // 같은 제목으로 다시 저장해도 이전 폴더를 덮어쓰지 않습니다.
            for number in 1...10_000 {
                let folder = parent.appendingPathComponent(name + (number == 1 ? "" : " (\(number))"), isDirectory: true)
                if manager.fileExists(atPath: folder.path) { continue }
                do {
                    try commit { try manager.moveItem(at: staging, to: folder) }
                    return folder
                } catch where manager.fileExists(atPath: folder.path) {
                    try checkCancellation() // 다른 저장 작업이 먼저 같은 이름을 사용했다면 다음 번호를 고릅니다.
                }
            }
            throw AppFailure(message: "같은 이름의 폴더가 너무 많습니다. 다른 저장 위치를 선택하세요.")
        }
        let output = staging.appendingPathComponent("result")
        if format == .audio {
            try copyAudio(from: URL(fileURLWithPath: entry.audio_path), to: output, copied: copied)
        } else {
            try writeText(format == .transcript ? Self.transcript(entry) : Self.markdown(entry), to: output)
        }
        try commit {
            if manager.fileExists(atPath: target.path) {
                guard replaceExisting else { throw AppFailure(message: "같은 이름의 파일이 있습니다. 다른 이름으로 저장하세요.") }
                guard try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw AppFailure(message: "일반 파일만 바꿀 수 있습니다. 다른 이름으로 저장하세요.")
                }
                _ = try manager.replaceItemAt(target, withItemAt: output, options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: output, to: target)
            }
        }
        return target
    }

    private func commit(_ operation: () throws -> Void) throws {
        // 최종 이동과 취소가 겹치면 먼저 시작한 쪽을 완료합니다. 중간 파일은 최종 이름으로 보이지 않습니다.
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try operation()
    }

    private func writeText(_ text: String, to url: URL) throws {
        try checkCancellation()
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func copyAudio(from source: URL, to output: URL, copied: (Int64) -> Void) throws {
        let values: URLResourceValues
        do { values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
        catch { throw AppFailure(message: "녹음 파일을 찾거나 읽을 수 없습니다. 앱에 원본이 남아 있는지 확인하세요.") }
        guard values.isRegularFile == true else { throw AppFailure(message: "녹음 경로가 일반 파일이 아닙니다.") }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw AppFailure(message: "녹음 사본을 만들 수 없습니다. 저장 공간과 폴더 권한을 확인하세요.")
        }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var count: Int64 = 0
        // 긴 회의 파일 전체를 메모리에 올리지 않고 1MiB씩 복사하고 취소를 확인합니다.
        while true {
            try checkCancellation()
            guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
            try writer.write(contentsOf: data)
            count += Int64(data.count)
            copied(count)
        }
        guard count == Int64(values.fileSize ?? -1) else {
            throw AppFailure(message: "저장하는 동안 녹음 파일 크기가 바뀌었습니다. 다시 시도하세요.")
        }
        try writer.synchronize()
        try writer.close()
    }
}
