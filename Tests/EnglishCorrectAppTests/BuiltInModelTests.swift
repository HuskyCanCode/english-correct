import XCTest
import CryptoKit
import EnglishCorrectCore
@testable import EnglishCorrect

final class BuiltInModelTests: XCTestCase {
    func testDownloadVerifyDeleteAndDownloadAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("GGUF tiny verified test fixture".utf8)
        let file = fixture(data)
        let store = BuiltInModelStore(root: root, catalog: ["fast": [file]], downloader: { _, progress in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            await progress(ModelDownloadProgress(status: "Downloading", completedBytes: Int64(data.count), totalBytes: Int64(data.count)))
            return url
        })
        let empty = try await store.installedModelIDs()
        XCTAssertTrue(empty.isEmpty)
        try await store.download("fast") { _ in }
        let installed = try await store.installedModelIDs()
        XCTAssertEqual(installed, ["fast"])
        let url = try await store.modelURL(for: "fast")
        XCTAssertEqual(try Data(contentsOf: url), data)
        // Corruption must invalidate a previously verified model, even at the same size.
        try Data(repeating: 0, count: data.count).write(to: url)
        let corrupted = try await store.installedModelIDs()
        XCTAssertTrue(corrupted.isEmpty)
        try await store.download("fast") { _ in }
        try await store.delete("fast")
        let deleted = try await store.installedModelIDs()
        XCTAssertTrue(deleted.isEmpty)
        try await store.download("fast") { _ in }
        let restored = try await store.installedModelIDs()
        XCTAssertEqual(restored, ["fast"])
    }
    func testBadDownloadAndMissingShardNeverBecomeInstalled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("GGUF good".utf8)
        let store = BuiltInModelStore(root: root, catalog: ["fast": [fixture(data)]], downloader: { _, _ in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("GGUF evil".utf8).write(to: url)
            return url
        })
        do { try await store.download("fast") { _ in }; XCTFail("Unverified model accepted") } catch {}
        let installed = try await store.installedModelIDs()
        XCTAssertTrue(installed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fast/complete.json").path))
    }
    func testIncompleteProKeepsVerifiedShardForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("GGUF verified shard".utf8)
        let hash = fixture(data).sha256
        let files = ["one.gguf", "two.gguf"].map { BuiltInModelFile(name: $0, url: URL(string: "https://huggingface.co/test/" + $0)!, bytes: Int64(data.count), sha256: hash) }
        let source = ShardSource(data: data)
        let store = BuiltInModelStore(root: root, catalog: ["pro": files], downloader: { url, _ in try await source.fetch(url) })
        do { try await store.download("pro") { _ in }; XCTFail() } catch {}
        let incomplete = try await store.installedModelIDs()
        XCTAssertTrue(incomplete.isEmpty)
        try await store.download("pro") { _ in }
        let complete = try await store.installedModelIDs()
        XCTAssertEqual(complete, ["pro"])
        let requests = await source.requests
        XCTAssertEqual(requests, ["one.gguf", "two.gguf", "two.gguf"])
    }

    func testDeletionRejectsUnknownIDsAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("fast"), withDestinationURL: outside)
        let store = BuiltInModelStore(root: root)
        for id in ["../", "fast"] {
            do { try await store.delete(id); XCTFail("Unsafe deletion accepted") } catch {}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
    func testCancellationDoesNotMarkModelInstalled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BuiltInModelStore(root: root, catalog: ["fast": [fixture(Data("GGUF".utf8))]], downloader: { _, _ in throw CancellationError() })
        do { try await store.download("fast") { _ in }; XCTFail() } catch is CancellationError {} catch { XCTFail("Wrong error: \(error)") }
        let models = try await store.installedModelIDs()
        XCTAssertTrue(models.isEmpty)
        try await store.delete("fast")
    }
    @MainActor
    func testFreshInstallationUsesBuiltInAndRetainsLegacySelection() throws {
        let name = "EnglishCorrect.BuiltInTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(fresh.provider, .builtIn)
        XCTAssertEqual(fresh.section, "Setup")
        XCTAssertFalse(fresh.enabled)
        defaults.set("qwen2.5-1.5b-instruct", forKey: "model")
        let legacy = AppModel(defaults: defaults, startMonitoring: false)
        XCTAssertEqual(legacy.provider, .lmStudio)
        legacy.useBuiltInAI()
        XCTAssertEqual(legacy.provider, .builtIn)
        XCTAssertEqual(legacy.model, "")
        XCTAssertFalse(legacy.enabled)
    }
    @MainActor
    func testRuntimeBindsOnlyLoopbackAndMissingEngineFails() throws {
        let args = BuiltInModelRuntime.arguments(modelID: "fast", modelURL: URL(fileURLWithPath: "/tmp/test.gguf"), port: 56789)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--host")) + 1], "127.0.0.1")
        XCTAssertTrue(args.contains("--no-webui"))
        XCTAssertTrue(args.contains("--log-disable"))
        XCTAssertFalse(args.contains("--tools"))
        let engine = BuiltInModelRuntime(executable: URL(fileURLWithPath: "/missing-engine"))
        XCTAssertThrowsError(try engine.checkBundledEngine())
        engine.shutdown()
    }
    private func fixture(_ data: Data) -> BuiltInModelFile {
        BuiltInModelFile(name: "model.gguf", url: URL(string: "https://huggingface.co/test/model")!, bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

private actor ShardSource {
    let data: Data
    var requests: [String] = []
    init(data: Data) { self.data = data }
    func fetch(_ url: URL) throws -> URL {
        requests.append(url.lastPathComponent)
        if requests.count == 2 { throw URLError(.networkConnectionLost) }
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: result)
        return result
    }
}
