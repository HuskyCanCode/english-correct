import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

@MainActor
final class ModelDeletionAppTests: XCTestCase {
    func testDeletingAnActiveRuntimeAliasClearsSelectionAndOldCorrections() async throws {
        let fixture = try await Fixture(model: "manually-selected-runtime-alias")
        defer { fixture.clean() }
        let request = try await fixture.request()
        fixture.app.setAutomaticSuggestions(true)
        XCTAssertTrue(fixture.app.enabled, "Deletion must pause an actually enabled session.")
        let old = Correction(original: fixture.app.draft, corrected: "Corrected draft.", explanation: "")
        fixture.app.draftCorrection = old
        fixture.app.externalCorrection = old
        fixture.app.models = [fixture.backend.modelID, fixture.app.model, "unrelated-model"]
        fixture.backend.removedIDs = [fixture.backend.modelID, fixture.app.model]

        fixture.app.prepareForModelDeletion(request)
        XCTAssertNil(fixture.app.draftCorrection)
        XCTAssertNil(fixture.app.externalCorrection)
        fixture.library.confirmDeletion { fixture.app.modelWasDeleted($0) }
        await waitUntil { fixture.library.deletingID == nil }

        XCTAssertEqual(fixture.app.model, "")
        XCTAssertEqual(fixture.defaults.string(forKey: "model"), "")
        XCTAssertEqual(fixture.app.models, ["unrelated-model"])
        XCTAssertFalse(fixture.app.enabled)
        XCTAssertTrue(fixture.app.connectionStatus.contains("Download or choose"))
        XCTAssertNil(fixture.library.installedID(ModelCatalog.recommendations[0]))
    }

    func testDeletingUnusedModelPreservesCurrentChoiceAndCancelDoesNothing() async throws {
        let fixture = try await Fixture(model: "unrelated-model")
        defer { fixture.clean() }
        _ = try await fixture.request()
        fixture.library.cancelDeletion()
        fixture.library.confirmDeletion { _ in XCTFail("Cancelled deletion completed") }
        XCTAssertEqual(fixture.backend.deleted, 0)
        XCTAssertEqual(fixture.app.model, "unrelated-model")

        let request = try await fixture.request()
        fixture.app.prepareForModelDeletion(request)
        fixture.library.confirmDeletion { fixture.app.modelWasDeleted($0) }
        await waitUntil { fixture.library.deletingID == nil }
        XCTAssertEqual(fixture.backend.deleted, 1)
        XCTAssertEqual(fixture.app.model, "unrelated-model")
    }

    func testReviewWaitsDuringDeletionAndNewerSelectionIsPreserved() async throws {
        let fixture = try await Fixture(model: "qwen2.5-1.5b-instruct")
        defer { fixture.clean() }
        let request = try await fixture.request()
        fixture.app.prepareForModelDeletion(request)
        fixture.library.confirmDeletion { fixture.app.modelWasDeleted($0) }

        // The operation is marked busy synchronously, before its async work starts.
        fixture.app.checkDraft()
        fixture.app.triggerShortcut()
        XCTAssertFalse(fixture.app.draftBusy)
        XCTAssertTrue(fixture.app.draftStatus.contains("deletion"))
        XCTAssertFalse(fixture.app.externalBusy)
        fixture.app.model = "newer-model"
        await waitUntil { fixture.library.deletingID == nil }
        XCTAssertEqual(fixture.app.model, "newer-model")
    }

    func testFailedDeletionKeepsActiveModelSelected() async throws {
        let fixture = try await Fixture(model: "qwen2.5-1.5b-instruct")
        defer { fixture.clean() }
        let request = try await fixture.request()
        fixture.backend.fail = true
        fixture.app.prepareForModelDeletion(request)
        fixture.library.confirmDeletion { fixture.app.modelWasDeleted($0) }
        await waitUntil { fixture.library.deletingID == nil }
        XCTAssertEqual(fixture.app.model, fixture.backend.modelID)
        XCTAssertNotNil(fixture.library.installedID(ModelCatalog.recommendations[0]))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class Fixture {
    let suite = "EnglishCorrect.DeletionAppTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let backend = DeletionBackend()
    let library: ModelLibrary
    let monitor: AccessibilityMonitor
    let app: AppModel

    init(model: String) async throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(model, forKey: "model")
        defaults.set(try JSONEncoder().encode([
            AppPermission(id: SetupTestAccessibilityBackend.bundleID, name: "Deletion Test Editor", allowed: true)
        ]), forKey: "appPermissions")
        library = ModelLibrary(defaults: defaults, backend: backend)
        monitor = AccessibilityMonitor(backend: SetupTestAccessibilityBackend())
        app = AppModel(defaults: defaults, monitor: monitor, modelLibrary: library, startMonitoring: false,
                       listModels: { _ in [model] }, correctText: { text, _ in
            Correction(original: text, corrected: "She doesn't like apples.", explanation: "Verb agreement.")
        })
        app.shortcutRegistered = true
        app.checkSetup()
        for _ in 0..<400 {
            if app.setupAIState != .checking { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(app.setupAIState, .ready)
        guard app.setupAIState == .ready else { throw LocalAIError.invalidResponse }
    }
    func request() async throws -> ModelDeletionRequest {
        library.refresh()
        for _ in 0..<100 {
            if !library.checking { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        library.requestDeletion(ModelCatalog.recommendations[0])
        return try XCTUnwrap(library.pendingDeletion)
    }
    func clean() { app.model = ""; monitor.stop(); defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class DeletionBackend: ModelLibraryBackend {
    let modelID = "qwen2.5-1.5b-instruct"
    var removedIDs: [String] = ["qwen2.5-1.5b-instruct"]
    var deleted = 0
    var fail = false
    func installed(_ config: LocalAIConfiguration) async throws -> [String] { deleted == 0 || fail ? [modelID] : [] }
    func delete(_ id: String, spec: DownloadSpec, config: LocalAIConfiguration) async throws -> [String] {
        deleted += 1
        if fail { throw ModelDownloadError.connectionFailed }
        return removedIDs
    }
    func start(_ spec: DownloadSpec, config: LocalAIConfiguration) async throws -> DownloadUpdate { throw ModelDownloadError.invalidSpecification }
    func poll(_ jobID: String, config: LocalAIConfiguration) async throws -> DownloadUpdate { throw ModelDownloadError.invalidSpecification }
    func pull(_ spec: DownloadSpec, config: LocalAIConfiguration, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws { throw ModelDownloadError.invalidSpecification }
    func prepare(_ id: String, config: LocalAIConfiguration) async throws -> String { throw ModelDownloadError.invalidSpecification }
}
