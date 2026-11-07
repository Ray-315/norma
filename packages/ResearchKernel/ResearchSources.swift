import Foundation
import PDFKit
import ResearchContracts
import EvidenceEngine

extension ResearchService {
    public func importSources(_ command: SourceImportCommand) async throws -> ResearchSnapshot {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision else { throw NormaError.conflict }
        guard !state.operation.occupiesSlot, !(try await store.invocations()).contains(where: { $0.researchID == state.id && ($0.state == .running || $0.state == .queued) }) else { throw NormaError.forbidden("请等当前任务结束后再修改研究资料。") }
        guard !command.paths.isEmpty, command.paths.count <= 20, !command.project || command.paths.count == 1 else { throw NormaError.invalid("每次最多添加 20 个附件或 1 个项目文件夹。") }
        var sources = state.sources ?? []
        var objects: [EvidenceArtifact] = []
        for path in command.paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if command.project {
                guard values.isDirectory == true else { throw NormaError.invalid("请选择项目文件夹。") }
                sources.removeAll { $0.kind == .project }
                sources.append(ResearchSource(kind: .project, name: url.lastPathComponent, path: url.path,
                    bookmark: try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)))
            } else {
                guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20 * 1024 * 1024 else { throw NormaError.invalid("附件必须是普通文件，且每个不超过 20 MB。") }
                guard !ResearchContextReader.isExcluded(url.lastPathComponent) else { throw NormaError.forbidden("不能将凭据或隐藏配置文件作为研究附件。") }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data()
                guard data.count <= 20 * 1024 * 1024 else { throw NormaError.invalid("附件超过 20 MB。") }
                let object = try await artifacts.put(data, kind: .data, researchID: state.id)
                if !sources.contains(where: { $0.artifact?.hash == object.hash && $0.name == url.lastPathComponent }) {
                    sources.append(ResearchSource(kind: .attachment, name: url.lastPathComponent, artifact: object))
                    objects.append(object)
                }
            }
        }
        guard sources.filter({ $0.kind == .attachment }).count <= 50, sources.filter({ $0.kind == .project }).count <= 1 else { throw NormaError.invalid("每个课题最多保留 50 个附件和 1 个项目文件夹。") }
        state.sources = sources
        return try await store.update(state, expected: command.revision, kind: "sources.updated", detail: "研究资料已更新", artifacts: objects)
    }
    public func removeSource(_ command: SourceRemoveCommand) async throws -> ResearchSnapshot {
        var state = try await store.snapshot(command.id)
        guard state.revision == command.revision else { throw NormaError.conflict }
        guard !state.operation.occupiesSlot, !(try await store.invocations()).contains(where: { $0.researchID == state.id && ($0.state == .running || $0.state == .queued) }) else { throw NormaError.forbidden("请等当前任务结束后再修改研究资料。") }
        state.sources?.removeAll { $0.id == command.sourceID }
        return try await store.update(state, expected: command.revision, kind: "sources.updated", detail: "已移除资料引用；原文件未删除")
    }
}

public enum ResearchContextReader {
    static let textExtensions: Set<String> = ["md", "txt", "rst", "csv", "json", "yaml", "yml", "toml", "py", "swift", "r", "jl", "js", "ts", "c", "cpp", "h", "tex", "log"]
    public static func isExcluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(".") || ["node_modules", "build", "dist", "deriveddata", "__pycache__", "venv", "env", "auth.json", "credentials.json", "id_rsa", "id_ed25519"].contains(lower)
            || ["pem", "key", "p12", "pfx"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
    static func extract(_ data: Data, name: String) -> String {
        if URL(fileURLWithPath: name).pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(data: data) else { return "[PDF 无法读取]" }
            var result = ""
            for index in 0..<min(document.pageCount, 20) {
                result += String((document.page(at: index)?.string ?? "").prefix(16_000)) + "\n"
                if result.count >= 32_000 { break }
            }
            return result.isEmpty ? "[此 PDF 没有可提取文本，需要文字版资料]" : String(result.prefix(32_000)) + "\n[PDF 读取上限：20 页、32000 字符]"
        }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return "[此附件已保存，当前不支持提取其文本]" }
        return String(text.prefix(32_000)) + (text.count > 32_000 ? "\n[内容已截断]" : "")
    }
    public static func read(_ state: ResearchSnapshot, artifacts: ArtifactStore) async throws -> String {
        var sections: [String] = []; var remaining = 64_000
        func append(_ title: String, _ body: String) {
            guard remaining > 0 else { return }
            let section = "\n--- " + title + " ---\n" + body
            let clipped = String(section.prefix(remaining)); remaining -= clipped.count; sections.append(clipped)
        }
        for source in state.sources ?? [] where source.kind == .attachment {
            guard remaining > 0 else { break }
            guard let artifact = source.artifact else { continue }
            append(source.name + " · 资料校验值 " + artifact.hash, extract(try await artifacts.read(artifact, researchID: state.id), name: source.name))
        }
        if let project = state.sources?.first(where: { $0.kind == .project }), let path = project.path, remaining > 0 {
            var stale = false
            let root: URL
            if let bookmark = project.bookmark {
                root = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale).resolvingSymlinksInPath()
            } else { root = URL(fileURLWithPath: path).resolvingSymlinksInPath() }
            let access = root.startAccessingSecurityScopedResource(); defer { if access { root.stopAccessingSecurityScopedResource() } }
            let files = try projectFiles(root)
            append("项目文件夹", root.path + "\n读取范围：最多 24 个文本文件，总上下文最多 64000 字符。")
            for file in files.prefix(24) where remaining > 0 {
                let resolved = file.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root.path + "/"), try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let handle = try FileHandle(forReadingFrom: resolved); defer { try? handle.close() }
                let data = try handle.read(upToCount: 128 * 1024) ?? Data()
                append(String(file.path.dropFirst(root.path.count + 1)), extract(data, name: file.lastPathComponent))
            }
        }
        if remaining == 0 { sections.append("[研究资料达到上下文读取上限，剩余内容未读取]") }
        return sections.joined(separator: "\n")
    }
    public static func projectFiles(_ root: URL) throws -> [URL] {
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw NormaError.invalid("项目文件夹已不存在，请重新选择。") }
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else { throw NormaError.unavailable("无法读取项目文件夹。") }
        var files: [URL] = []; var visited = 0
        for case let file as URL in enumerator {
            visited += 1; if visited > 1000 { break }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            if values.isSymbolicLink == true || isExcluded(file.lastPathComponent) || file.pathComponents.count - root.pathComponents.count > 4 { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true, textExtensions.contains(file.pathExtension.lowercased()) { files.append(file) }
        }
        if let scanError { throw scanError }
        func priority(_ file: URL) -> Int {
            let name = file.lastPathComponent.lowercased()
            if ["readme.md", "memory.md", "progress.md", "notes.md", "研究记忆.md", "研究进展.md"].contains(name) { return 0 }
            return file.pathExtension.lowercased() == "md" ? 1 : 2
        }
        return files.sorted { priority($0) == priority($1) ? $0.path < $1.path : priority($0) < priority($1) }
    }
}
