import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

@MainActor
final class LMStudioModelRemovalTests: XCTestCase {
    private let fast = ModelCatalog.recommendations[0]
    private let pro = ModelCatalog.recommendations[1]
    private let config = LocalAIConfiguration(provider: .lmStudio, baseURL: "http://127.0.0.1:1234", model: "test")

    func testTrashesOnlyExactFastWeightsAfterUnloadAndCanRestoreDownload() async throws {
        let fixture = try Files()
        defer { fixture.clean() }
        let weights = try fixture.writeFast()
        let neighbor = try fixture.write("Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q8_0.gguf")
        var unloaded = false
        let remover = LMStudioModelRemoval(root: fixture.models, unload: { id, spec, _ in
            XCTAssertEqual(id, "qwen2.5-1.5b-instruct")
            XCTAssertEqual(spec, self.fast.downloadSpec)
            XCTAssertTrue(FileManager.default.fileExists(atPath: weights.path))
            unloaded = true
            return ["runtime-alias"]
        }, trash: { file in
            XCTAssertTrue(unloaded)
            try fixture.trash(file)
        })
        let removedIDs = try await remover.remove("qwen2.5-1.5b-instruct", spec: fast.downloadSpec, configuration: config)
        XCTAssertEqual(removedIDs, ["qwen2.5-1.5b-instruct", "runtime-alias"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: weights.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))
        XCTAssertEqual(fixture.trashed.map(\.lastPathComponent), [weights.lastPathComponent])
        // The repository remains intact so a later download can write the same file.
        _ = try fixture.writeFast()
        XCTAssertTrue(FileManager.default.fileExists(atPath: weights.path))
    }

    func testBothProShardsAreRequiredAndOnlyThoseShardsAreTrashed() async throws {
        let fixture = try Files()
        defer { fixture.clean() }
        let names = (1...2).map { "Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q4_k_m-0000\($0)-of-00002.gguf" }
        _ = try fixture.write(names[0])
        var unloadCount = 0
        let remover = LMStudioModelRemoval(root: fixture.models, unload: { _, _, _ in unloadCount += 1; return [] }, trash: fixture.trash)
        await expect(.missingFiles) { try await remover.remove("qwen2.5-7b-instruct", spec: self.pro.downloadSpec, configuration: self.config) }
        XCTAssertEqual(unloadCount, 0)
        XCTAssertTrue(fixture.trashed.isEmpty)

        _ = try fixture.write(names[1])
        try await remover.remove("qwen2.5-7b-instruct", spec: pro.downloadSpec, configuration: config)
        XCTAssertEqual(unloadCount, 1)
        XCTAssertEqual(fixture.trashed.count, 2)
    }

    func testSymlinkedFileOrRepositoryNeverUnloadsOrTrashes() async throws {
        for linkRepository in [false, true] {
            let fixture = try Files()
            defer { fixture.clean() }
            let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let target = outside.appendingPathComponent("qwen2.5-1.5b-instruct-q4_k_m.gguf")
            try Data("GGUF fixture".utf8).write(to: target)
            let repository = fixture.models.appendingPathComponent("Qwen/Qwen2.5-1.5B-Instruct-GGUF")
            try FileManager.default.createDirectory(at: repository.deletingLastPathComponent(), withIntermediateDirectories: true)
            if linkRepository {
                try FileManager.default.createSymbolicLink(at: repository, withDestinationURL: outside)
            } else {
                try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: repository.appendingPathComponent(target.lastPathComponent), withDestinationURL: target)
            }
            let remover = LMStudioModelRemoval(root: fixture.models, unload: { _, _, _ in XCTFail("Unsafe files must not unload a model"); return [] }, trash: fixture.trash)
            await expect(.unsafeFile) { try await remover.remove("qwen2.5-1.5b-instruct", spec: self.fast.downloadSpec, configuration: self.config) }
            XCTAssertTrue(fixture.trashed.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testUnsupportedIdentifiersAndSpecsNeverTouchTheModel() async throws {
        let fixture = try Files()
        defer { fixture.clean() }
        _ = try fixture.writeFast()
        let remover = LMStudioModelRemoval(root: fixture.models, unload: { _, _, _ in XCTFail("Unknown model must not unload"); return [] }, trash: fixture.trash)
        for id in ["../qwen2.5-1.5b-instruct", "lmstudio-community/qwen2.5-1.5b-instruct", "qwen2.5-coder-1.5b-instruct", "qwen2.5-1.5b-instruct@q8_0"] {
            await expect(.unsupportedModel) { try await remover.remove(id, spec: self.fast.downloadSpec, configuration: self.config) }
        }
        let altered = DownloadSpec(catalogID: "fast", lmStudioRepository: fast.sourceURL.absoluteString, quantization: "Q8_0", ollamaModel: fast.downloadSpec.ollamaModel)
        await expect(.unsupportedModel) { try await remover.remove("qwen2.5-1.5b-instruct", spec: altered, configuration: self.config) }
        XCTAssertTrue(fixture.trashed.isEmpty)
    }

    func testCustomConfiguredRootWorksAndMalformedSettingsDoNotFallBack() async throws {
        let fixture = try Files()
        defer { fixture.clean() }
        _ = try fixture.writeFast()
        let settings = fixture.base.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["downloadsFolder": fixture.models.path]).write(to: settings)
        let remover = LMStudioModelRemoval(settingsURL: settings, fallbackRoot: fixture.base.appendingPathComponent("unused"), unload: { _, _, _ in [] }, trash: fixture.trash)
        try await remover.remove("qwen2.5-1.5b-instruct", spec: fast.downloadSpec, configuration: config)
        XCTAssertEqual(fixture.trashed.count, 1)

        for data in [Data("not json".utf8), try JSONSerialization.data(withJSONObject: ["downloadsFolder": "relative/path"])] {
            try data.write(to: settings)
            let guarded = LMStudioModelRemoval(settingsURL: settings, fallbackRoot: fixture.models, unload: { _, _, _ in XCTFail("Malformed settings must fail before unload"); return [] }, trash: fixture.trash)
            do {
                try await guarded.remove("qwen2.5-1.5b-instruct", spec: fast.downloadSpec, configuration: config)
                XCTFail("Accepted malformed settings")
            } catch { /* No fallback deletion is allowed. */ }
        }
        XCTAssertEqual(fixture.trashed.count, 1)
    }

    func testFileChangedDuringUnloadIsNotTrashed() async throws {
        let fixture = try Files()
        defer { fixture.clean() }
        let weights = try fixture.writeFast()
        let remover = LMStudioModelRemoval(root: fixture.models, unload: { _, _, _ in
            try Data("GGUF replaced fixture with new contents".utf8).write(to: weights, options: .atomic)
            return []
        }, trash: fixture.trash)
        await expect(.changedFiles) { try await remover.remove("qwen2.5-1.5b-instruct", spec: self.fast.downloadSpec, configuration: self.config) }
        XCTAssertTrue(fixture.trashed.isEmpty)
    }

    func testUnloadFailureLeavesEveryFileInPlace() async throws {
        let fixture = try Files()
        defer { fixture.clean() }
        let weights = try fixture.writeFast()
        let remover = LMStudioModelRemoval(root: fixture.models, unload: { _, _, _ in throw ModelDownloadError.connectionFailed }, trash: fixture.trash)
        do {
            try await remover.remove("qwen2.5-1.5b-instruct", spec: fast.downloadSpec, configuration: config)
            XCTFail("Unload failure accepted")
        } catch { XCTAssertEqual(error as? ModelDownloadError, .connectionFailed) }
        XCTAssertTrue(fixture.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: weights.path))
    }

    func testPartialTrashFailureReportsPartialRemovalWithoutDeletingNeighbors() async throws {
        let fixture = try Files()
        defer { fixture.clean() }
        for shard in 1...2 { _ = try fixture.write("Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q4_k_m-0000\(shard)-of-00002.gguf") }
        let remover = LMStudioModelRemoval(root: fixture.models, unload: { _, _, _ in [] }, trash: { file in
            if fixture.trashed.count == 1 { throw CocoaError(.fileWriteNoPermission) }
            try fixture.trash(file)
        })
        await expect(.partiallyRemoved) { try await remover.remove("qwen2.5-7b-instruct", spec: self.pro.downloadSpec, configuration: self.config) }
        XCTAssertEqual(fixture.trashed.count, 1)
    }

    func testNonGGUFAndNoOpTrashCannotReportSuccess() async throws {
        let fixture = try Files()
        defer { fixture.clean() }
        let weights = try fixture.writeFast()
        try Data("ordinary document".utf8).write(to: weights)
        let remover = LMStudioModelRemoval(root: fixture.models, unload: { _, _, _ in [] }, trash: { _ in })
        await expect(.unsafeFile) { try await remover.remove("qwen2.5-1.5b-instruct", spec: self.fast.downloadSpec, configuration: self.config) }
        _ = try fixture.writeFast()
        await expect(.trashFailed) { try await remover.remove("qwen2.5-1.5b-instruct", spec: self.fast.downloadSpec, configuration: self.config) }
    }

    private func expect(_ expected: LMStudioRemovalError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? LMStudioRemovalError, expected) }
    }
}

@MainActor
private final class Files {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("EnglishCorrect.RemovalTests.\(UUID().uuidString)")
    var models: URL { base.appendingPathComponent("models", isDirectory: true) }
    var trashed: [URL] = []

    init() throws { try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true) }
    func clean() { try? FileManager.default.removeItem(at: base) }
    func writeFast() throws -> URL { try write("Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf") }
    func write(_ path: String) throws -> URL {
        let file = models.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("GGUF disposable test fixture".utf8).write(to: file)
        return file
    }
    func trash(_ file: URL) throws {
        let folder = base.appendingPathComponent("fixture-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
        trashed.append(file)
    }
}
