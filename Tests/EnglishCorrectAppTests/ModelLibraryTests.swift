import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

final class ModelLibraryTests: XCTestCase {
    func testConfigurationAndRefreshNeverDownloadOrSelectAModel() async throws {
        try await Self.withLibrary { fixture in
            let library = fixture.library
            library.configure(fixture.ollama)
            fixture.backend.installedResult = [fixture.fast.downloadSpec.ollamaModel]
            XCTAssertTrue(fixture.backend.calls.isEmpty)

            library.refresh()
            try await Self.eventually { !library.checking }

            XCTAssertEqual(library.installedIDs, [fixture.fast.downloadSpec.ollamaModel])
            XCTAssertEqual(library.installedID(fixture.fast), fixture.fast.downloadSpec.ollamaModel)
            XCTAssertEqual(fixture.backend.calls, ["installed"])
            XCTAssertEqual(library.configuration.model, "current-model")
            XCTAssertFalse(library.isBusy)
        }
    }

    func testUseRequiresAnInstalledModel() async throws {
        try await Self.withLibrary { fixture in
            var selected: [String] = []
            fixture.library.use(fixture.fast) { selected.append($0) }
            await Task.yield()
            XCTAssertTrue(fixture.backend.calls.isEmpty)
            XCTAssertTrue(selected.isEmpty)
            XCTAssertNil(fixture.library.preparingID)
        }
    }

    func testExplicitUseSelectsReturnedInstanceOnlyAfterPreparationFinishes() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            let ready = LibrarySuspension<String>()
            fixture.backend.prepareHandler = { _, _ in try await ready.wait() }
            var selected: [String] = []

            fixture.library.use(fixture.fast) { selected.append($0) }
            try await Self.eventually { ready.isWaiting }
            XCTAssertEqual(fixture.backend.preparedIDs, [fixture.lmFastID])
            XCTAssertTrue(selected.isEmpty)
            XCTAssertEqual(fixture.library.preparingID, fixture.fast.id)

            ready.succeed("loaded-instance-42")
            try await Self.eventually { fixture.library.preparingID == nil }
            XCTAssertEqual(selected, ["loaded-instance-42"])
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], "Fast is ready for your writing.")
        }
    }

    func testPreparationFailureDoesNotSelectModel() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            fixture.backend.prepareHandler = { _, _ in throw ModelDownloadError.insufficientStorage }
            var selected: [String] = []
            fixture.library.use(fixture.fast) { selected.append($0) }
            try await Self.eventually { fixture.library.preparingID == nil }
            XCTAssertTrue(selected.isEmpty)
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], ModelDownloadError.insufficientStorage.localizedDescription)
            XCTAssertEqual(fixture.library.configuration.model, "current-model")
        }
    }

    func testManualModelSelectionInvalidatesPendingUse() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            let ready = LibrarySuspension<String>()
            fixture.backend.prepareHandler = { _, _ in try await ready.wait() }
            var selected: [String] = []
            fixture.library.use(fixture.fast) { selected.append($0) }
            try await Self.eventually { ready.isWaiting }

            fixture.library.configure(LocalAIConfiguration(provider: .lmStudio, baseURL: fixture.lmStudio.baseURL, model: "new-manual-choice"))
            ready.succeed("stale-loaded-instance")
            try await Self.eventually { fixture.backend.completedPreparations == 1 }
            await Task.yield()

            XCTAssertTrue(selected.isEmpty, "A completed load must not overwrite a newer manual selection.")
            XCTAssertTrue(fixture.library.selectedInstances.isEmpty)
            XCTAssertNil(fixture.library.preparingID)
            XCTAssertEqual(fixture.library.configuration.model, "new-manual-choice")
        }
    }

    func testSelectedInstanceAliasRestoresAndIsScopedToProviderAndServer() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            fixture.backend.prepareHandler = { _, _ in "local-runtime-alias" }
            fixture.library.use(fixture.fast) { _ in }
            try await Self.eventually { fixture.library.preparingID == nil }
            XCTAssertTrue(fixture.library.isSelected(fixture.fast, modelID: "local-runtime-alias"))
            XCTAssertFalse(fixture.library.isSelected(fixture.pro, modelID: "local-runtime-alias"))
            XCTAssertFalse(fixture.library.isSelected(fixture.fast, modelID: "another-choice"))

            let restored = ModelLibrary(defaults: fixture.defaults, backend: LibraryBackendStub())
            restored.configure(fixture.lmStudio)
            XCTAssertTrue(restored.isSelected(fixture.fast, modelID: "local-runtime-alias"))
            restored.configure(LocalAIConfiguration(provider: .lmStudio, baseURL: "http://127.0.0.1:9999", model: "local-runtime-alias"))
            XCTAssertFalse(restored.isSelected(fixture.fast, modelID: "local-runtime-alias"))
            restored.configure(fixture.ollama)
            XCTAssertFalse(restored.isSelected(fixture.fast, modelID: "local-runtime-alias"))
        }
    }

    func testDownloadCompletionDoesNotPrepareOrChangeActiveModel() async throws {
        try await Self.withLibrary { fixture in
            fixture.backend.startResult = fixture.complete(jobID: "job-complete")
            fixture.backend.installedResult = [fixture.lmFastID]
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }

            XCTAssertEqual(fixture.backend.calls, ["start", "installed"])
            XCTAssertEqual(fixture.library.configuration.model, "current-model")
            XCTAssertEqual(fixture.library.installedID(fixture.fast), fixture.lmFastID)
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], "Downloaded. Choose Use Fast when you’re ready.")
            XCTAssertTrue(fixture.library.savedJobs.isEmpty)
            XCTAssertTrue(fixture.backend.preparedIDs.isEmpty)
        }
    }

    func testCompletedDownloadIsNotSelectableUntilServerListsMatchingModel() async throws {
        try await Self.withLibrary { fixture in
            fixture.backend.startResult = fixture.complete()
            fixture.backend.installedResult = ["qwen2.5-coder-1.5b-instruct"]
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            var selected: [String] = []
            fixture.library.use(fixture.fast) { selected.append($0) }

            XCTAssertNil(fixture.library.installedID(fixture.fast))
            XCTAssertTrue(selected.isEmpty)
            XCTAssertTrue(fixture.backend.preparedIDs.isEmpty)
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], "Download finished. Choose Refresh to check whether the model is ready to use.")
        }
    }

    func testFailedAndTruncatedOllamaDownloadsNeverBecomeReady() async throws {
        for error in [ModelDownloadError.downloadFailed, .incompleteDownload] {
            try await Self.withLibrary { fixture in
                fixture.library.configure(fixture.ollama)
                fixture.backend.pullHandler = { _, _, progress in
                    await progress(ModelDownloadProgress(status: "Downloading model file", completedBytes: 4, totalBytes: 10))
                    throw error
                }
                fixture.library.download(fixture.fast)
                try await Self.eventually { fixture.library.activeDownloadID == nil }

                XCTAssertEqual(fixture.backend.calls, ["pull"])
                XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], error.localizedDescription)
                XCTAssertEqual(fixture.library.progress[fixture.fast.id]?.fraction, 0.4)
                XCTAssertNil(fixture.library.installedID(fixture.fast))
                XCTAssertEqual(fixture.library.configuration.model, "current-model")
            }
        }
    }

    func testStoppedOllamaDownloadIgnoresLateProgressAndError() async throws {
        try await Self.withLibrary { fixture in
            fixture.library.configure(fixture.ollama)
            let pending = LibrarySuspension<Void>()
            fixture.backend.pullHandler = { _, _, progress in
                try await pending.wait()
                await progress(ModelDownloadProgress(status: "stale progress", completedBytes: 10, totalBytes: 10))
                throw ModelDownloadError.incompleteDownload
            }
            fixture.library.download(fixture.fast)
            try await Self.eventually { pending.isWaiting }
            fixture.library.stopChecking()
            let stoppedMessage = fixture.library.cardMessages[fixture.fast.id]
            pending.succeed(())
            try await Self.eventually { fixture.backend.completedPulls == 1 }
            await Task.yield()

            XCTAssertNil(fixture.library.activeDownloadID)
            XCTAssertNil(fixture.library.progress[fixture.fast.id])
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], stoppedMessage)
            XCTAssertEqual(fixture.backend.calls, ["pull"])
            XCTAssertTrue(stoppedMessage?.contains("connection closed") == true)
        }
    }

    func testLMStudioJobPersistsAndExplicitResumePollsWithoutStartingAgain() async throws {
        try await Self.withLibrary { fixture in
            fixture.backend.startResult = DownloadUpdate(progress: ModelDownloadProgress(status: "Paused"), jobID: "saved-job-42", isPaused: true)
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            XCTAssertEqual(fixture.library.savedJobs.count, 1)

            let restartedBackend = LibraryBackendStub()
            restartedBackend.pollResult = fixture.complete(jobID: "saved-job-42")
            restartedBackend.installedResult = [fixture.lmFastID]
            let restarted = ModelLibrary(defaults: fixture.defaults, backend: restartedBackend, pollingNanoseconds: 0)
            restarted.configure(fixture.lmStudio)
            XCTAssertEqual(restarted.savedJob(fixture.fast)?.jobID, "saved-job-42")
            XCTAssertTrue(restartedBackend.calls.isEmpty, "Restoring a job must wait for an explicit resume action.")

            restarted.resume(fixture.fast)
            try await Self.eventually { restarted.activeDownloadID == nil }
            XCTAssertEqual(restartedBackend.calls, ["poll", "installed"])
            XCTAssertEqual(restartedBackend.polledIDs, ["saved-job-42"])
            XCTAssertEqual(restarted.installedID(fixture.fast), fixture.lmFastID)
            XCTAssertTrue(restarted.savedJobs.isEmpty)
            let again = ModelLibrary(defaults: fixture.defaults, backend: LibraryBackendStub())
            XCTAssertTrue(again.savedJobs.isEmpty, "Completed jobs must also be removed from persistent storage.")
        }
    }

    func testStopWhileLMStudioStartsStillPersistsReturnedJob() async throws {
        try await Self.withLibrary { fixture in
            let pending = LibrarySuspension<DownloadUpdate>()
            fixture.backend.startHandler = { _, _ in
                let response = try await pending.wait()
                // A real metadata request checks cancellation before returning its job ID.
                try Task.checkCancellation()
                return response
            }
            fixture.library.download(fixture.fast)
            try await Self.eventually { pending.isWaiting }
            fixture.library.stopChecking()
            let stoppedMessage = fixture.library.cardMessages[fixture.fast.id]
            pending.succeed(DownloadUpdate(progress: ModelDownloadProgress(status: "Downloading"), jobID: "late-job"))
            try await Self.eventually { fixture.library.savedJob(fixture.fast) != nil }

            XCTAssertNil(fixture.library.activeDownloadID)
            XCTAssertEqual(fixture.library.savedJob(fixture.fast)?.jobID, "late-job")
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], stoppedMessage)
            XCTAssertEqual(fixture.backend.calls, ["start"])
        }
    }

    func testDelayedOldStartCannotOverwriteNewerSavedDownloadJob() async throws {
        try await Self.withLibrary { fixture in
            let oldStart = LibrarySuspension<DownloadUpdate>()
            var starts = 0
            fixture.backend.startHandler = { _, _ in
                starts += 1
                if starts == 1 { return try await oldStart.wait() }
                return DownloadUpdate(progress: ModelDownloadProgress(status: "Paused"), jobID: "new-job", isPaused: true)
            }
            fixture.library.download(fixture.fast)
            try await Self.eventually { oldStart.isWaiting }
            fixture.library.stopChecking()
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            XCTAssertEqual(fixture.library.savedJob(fixture.fast)?.jobID, "new-job")

            oldStart.succeed(DownloadUpdate(progress: ModelDownloadProgress(status: "Downloading"), jobID: "old-job"))
            try await Self.eventually { fixture.backend.completedStarts == 2 }
            await Task.yield()
            XCTAssertEqual(fixture.library.savedJob(fixture.fast)?.jobID, "new-job")
            XCTAssertEqual(fixture.backend.calls, ["start", "start"])
        }
    }

    func testLMStudioPollFailureKeepsJobForRetry() async throws {
        try await Self.withLibrary { fixture in
            fixture.backend.startResult = DownloadUpdate(progress: ModelDownloadProgress(status: "Downloading"), jobID: "retry-job")
            fixture.backend.pollHandler = { _, _ in throw ModelDownloadError.connectionFailed }
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            XCTAssertEqual(fixture.backend.calls, ["start", "poll"])
            XCTAssertEqual(fixture.library.savedJob(fixture.fast)?.jobID, "retry-job")
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], ModelDownloadError.connectionFailed.localizedDescription)
            XCTAssertNil(fixture.library.installedID(fixture.fast))
        }
    }

    func testMissingLMStudioJobStopsWithActionableMessage() async throws {
        try await Self.withLibrary { fixture in
            fixture.backend.startResult = DownloadUpdate(progress: ModelDownloadProgress(status: "Downloading"))
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            XCTAssertEqual(fixture.backend.calls, ["start"])
            XCTAssertTrue(fixture.library.cardMessages[fixture.fast.id]?.contains("did not return a download job") == true)
            XCTAssertTrue(fixture.library.savedJobs.isEmpty)
        }
    }

    func testServerChangeIgnoresStaleRefreshAndPreparationResponses() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            let pendingRefresh = LibrarySuspension<[String]>()
            let pendingPrepare = LibrarySuspension<String>()
            fixture.backend.installedHandler = { _ in try await pendingRefresh.wait() }
            fixture.backend.prepareHandler = { _, _ in try await pendingPrepare.wait() }
            var selected: [String] = []
            fixture.library.refresh()
            fixture.library.use(fixture.fast) { selected.append($0) }
            try await Self.eventually { pendingRefresh.isWaiting && pendingPrepare.isWaiting }

            fixture.library.configure(fixture.ollama)
            pendingRefresh.succeed([fixture.lmFastID])
            pendingPrepare.succeed("stale-instance")
            try await Self.eventually { fixture.backend.completedInstalled == 2 && fixture.backend.completedPreparations == 1 }
            await Task.yield()

            XCTAssertTrue(fixture.library.installedIDs.isEmpty)
            XCTAssertTrue(selected.isEmpty)
            XCTAssertFalse(fixture.library.checking)
            XCTAssertFalse(fixture.library.isBusy)
            XCTAssertTrue(fixture.library.cardMessages.isEmpty)
        }
    }

    func testServerChangeIgnoresOldDownloadButKeepsJobScopedToOriginalServer() async throws {
        try await Self.withLibrary { fixture in
            let pending = LibrarySuspension<DownloadUpdate>()
            fixture.backend.startHandler = { _, _ in try await pending.wait() }
            fixture.library.download(fixture.fast)
            try await Self.eventually { pending.isWaiting }
            fixture.library.configure(fixture.ollama)
            pending.succeed(fixture.complete(jobID: "original-server-job"))
            try await Self.eventually { !fixture.library.savedJobs.isEmpty }

            XCTAssertEqual(fixture.backend.calls, ["start"])
            XCTAssertTrue(fixture.library.installedIDs.isEmpty)
            XCTAssertTrue(fixture.library.cardMessages.isEmpty)
            XCTAssertNil(fixture.library.activeDownloadID)
            XCTAssertNil(fixture.library.savedJob(fixture.fast))
            XCTAssertEqual(fixture.library.savedJobs.first?.provider, .lmStudio)
            XCTAssertEqual(fixture.library.savedJobs.first?.baseURL, fixture.lmStudio.baseURL)
        }
    }

    func testRefreshStartedBeforeCompletionCannotEraseDownloadedModel() async throws {
        try await Self.withLibrary { fixture in
            let oldRefresh = LibrarySuspension<[String]>()
            var discoveries = 0
            fixture.backend.installedHandler = { _ in
                discoveries += 1
                if discoveries == 1 { return try await oldRefresh.wait() }
                return [fixture.lmFastID]
            }
            fixture.library.refresh()
            try await Self.eventually { oldRefresh.isWaiting }
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            XCTAssertEqual(fixture.library.installedID(fixture.fast), fixture.lmFastID)

            oldRefresh.succeed([])
            try await Self.eventually { fixture.backend.completedInstalled == 2 }
            await Task.yield()
            XCTAssertEqual(fixture.library.installedID(fixture.fast), fixture.lmFastID)
            XCTAssertFalse(fixture.library.checking)
        }
    }

    func testManualModelChangeAllowsExistingDownloadToFinish() async throws {
        try await Self.withLibrary { fixture in
            let pending = LibrarySuspension<DownloadUpdate>()
            fixture.backend.startHandler = { _, _ in try await pending.wait() }
            fixture.backend.installedResult = [fixture.lmFastID]
            fixture.library.download(fixture.fast)
            try await Self.eventually { pending.isWaiting }
            fixture.library.configure(LocalAIConfiguration(provider: .lmStudio, baseURL: fixture.lmStudio.baseURL, model: "new-manual-choice"))
            XCTAssertEqual(fixture.library.activeDownloadID, fixture.fast.id)

            pending.succeed(fixture.complete())
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            XCTAssertEqual(fixture.library.installedID(fixture.fast), fixture.lmFastID)
            XCTAssertEqual(fixture.library.configuration.model, "new-manual-choice")
            XCTAssertEqual(fixture.backend.calls, ["start", "installed"])
        }
    }

    func testOnlyOneDownloadOrPreparationCanRunAtATime() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            let pendingDownload = LibrarySuspension<DownloadUpdate>()
            fixture.backend.startHandler = { _, _ in try await pendingDownload.wait() }
            fixture.library.download(fixture.fast)
            fixture.library.download(fixture.pro)
            fixture.library.use(fixture.fast) { _ in XCTFail("Use must be blocked during download") }
            fixture.library.refresh()
            try await Self.eventually { pendingDownload.isWaiting }
            XCTAssertEqual(fixture.backend.calls, ["installed", "start"])
            XCTAssertEqual(fixture.library.activeDownloadID, fixture.fast.id)
            pendingDownload.succeed(fixture.complete())
            try await Self.eventually { fixture.library.activeDownloadID == nil }

            let pendingPreparation = LibrarySuspension<String>()
            fixture.backend.prepareHandler = { _, _ in try await pendingPreparation.wait() }
            var selections = 0
            fixture.library.use(fixture.fast) { _ in selections += 1 }
            fixture.library.download(fixture.pro)
            fixture.library.use(fixture.fast) { _ in XCTFail("Second Use must be blocked") }
            fixture.library.refresh()
            try await Self.eventually { pendingPreparation.isWaiting }
            XCTAssertEqual(fixture.backend.calls, ["installed", "start", "installed", "prepare"])
            pendingPreparation.succeed("ready-instance")
            try await Self.eventually { fixture.library.preparingID == nil }
            XCTAssertEqual(selections, 1)
        }
    }

    func testDeleteRequiresConfirmationAndCancelKeepsTheDownload() async throws {
        try await Self.withLibrary { fixture in
            fixture.library.requestDeletion(fixture.fast)
            XCTAssertNil(fixture.library.pendingDeletion, "A missing download cannot be deleted.")
            try await fixture.installFast()
            fixture.library.requestDeletion(fixture.fast)
            let request = try XCTUnwrap(fixture.library.pendingDeletion)
            XCTAssertEqual(request.installedModelID, fixture.lmFastID)
            XCTAssertEqual(request.provider, .lmStudio)
            XCTAssertEqual(request.baseURL, fixture.lmStudio.baseURL)
            XCTAssertEqual(fixture.backend.calls, ["installed"])
            XCTAssertFalse(fixture.library.isBusy)

            fixture.library.cancelDeletion()
            fixture.library.confirmDeletion { _ in XCTFail("Cancel must not call back.") }
            await Task.yield()
            XCTAssertNil(fixture.library.pendingDeletion)
            XCTAssertTrue(fixture.backend.deletedIDs.isEmpty)
            XCTAssertEqual(fixture.library.installedIDs, [fixture.lmFastID])
        }
    }

    func testConfirmedDeleteUsesExactDownloadedIdentityAndCapturedRuntimeAlias() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            fixture.backend.prepareHandler = { _, _ in "runtime-alias:2" }
            fixture.library.use(fixture.fast) { _ in }
            try await Self.eventually { fixture.library.preparingID == nil }
            fixture.library.requestDeletion(fixture.fast)
            let request = try XCTUnwrap(fixture.library.pendingDeletion)
            XCTAssertTrue(request.matchesSelectedModel(fixture.lmFastID))
            XCTAssertTrue(request.matchesSelectedModel("runtime-alias:2"))
            XCTAssertFalse(request.matchesSelectedModel("current-model"), "An arbitrary current model is not an alias.")
            XCTAssertFalse(request.matchesSelectedModel("runtime-alias:3"))
            var deleted: [UUID] = []
            fixture.library.confirmDeletion { deleted.append($0.id) }
            try await Self.eventually { fixture.library.deletingID == nil }

            XCTAssertEqual(fixture.backend.deletedIDs, [fixture.lmFastID])
            XCTAssertEqual(fixture.backend.deleteConfigurations, [fixture.lmStudio])
            XCTAssertEqual(deleted, [request.id])
            XCTAssertTrue(fixture.library.installedIDs.isEmpty)
            XCTAssertTrue(fixture.library.selectedInstances.isEmpty)
            XCTAssertEqual(fixture.backend.calls, ["installed", "prepare", "delete", "installed"])
            let restored = ModelLibrary(defaults: fixture.defaults, backend: LibraryBackendStub())
            XCTAssertTrue(restored.selectedInstances.isEmpty)
        }
    }

    func testDeletedModelCanBeDownloadedAgainWithCleanProgressAndNoOldJob() async throws {
        try await Self.withLibrary { fixture in
            fixture.backend.startResult = DownloadUpdate(progress: ModelDownloadProgress(status: "Paused", completedBytes: 3, totalBytes: 10), jobID: "old-job", isPaused: true)
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            XCTAssertNotNil(fixture.library.savedJob(fixture.fast))
            XCTAssertNotNil(fixture.library.progress[fixture.fast.id])
            try await fixture.installFast()

            fixture.library.requestDeletion(fixture.fast)
            fixture.library.confirmDeletion { _ in }
            try await Self.eventually { fixture.library.deletingID == nil }
            XCTAssertNil(fixture.library.installedID(fixture.fast))
            XCTAssertNil(fixture.library.savedJob(fixture.fast))
            XCTAssertNil(fixture.library.progress[fixture.fast.id])
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], "Deleted. You can download Fast again.")

            fixture.backend.startResult = fixture.complete(jobID: "new-job")
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            XCTAssertEqual(fixture.library.installedID(fixture.fast), fixture.lmFastID)
            XCTAssertTrue(fixture.library.savedJobs.isEmpty)
            XCTAssertEqual(fixture.backend.calls, ["start", "installed", "delete", "installed", "start", "installed"])
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], "Downloaded. Choose Use Fast when you’re ready.")
        }
    }

    func testProviderVerifiedRuntimeAliasUpdatesTheDeletionCallbackWithoutGuessing() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            let runtimeAlias = "manually-loaded-instance:2"
            fixture.library.configure(LocalAIConfiguration(provider: .lmStudio, baseURL: fixture.lmStudio.baseURL, model: runtimeAlias))
            fixture.backend.deleteHandler = { id, _, _ in [id, runtimeAlias, runtimeAlias, ""] }
            fixture.library.requestDeletion(fixture.fast)
            let pending = try XCTUnwrap(fixture.library.pendingDeletion)
            XCTAssertFalse(pending.matchesSelectedModel(runtimeAlias), "An unknown alias cannot be inferred from the active model.")
            var completed: ModelDeletionRequest?
            fixture.library.confirmDeletion { completed = $0 }
            try await Self.eventually { fixture.library.deletingID == nil }

            let request = try XCTUnwrap(completed)
            XCTAssertEqual(request.id, pending.id)
            XCTAssertEqual(request.provider, pending.provider)
            XCTAssertEqual(request.baseURL, pending.baseURL)
            XCTAssertTrue(request.matchesSelectedModel(runtimeAlias))
            XCTAssertEqual(request.selectedInstanceIDs, [fixture.lmFastID, runtimeAlias])
            XCTAssertFalse(request.matchesSelectedModel("manually-loaded-instance:3"))
            XCTAssertFalse(request.matchesSelectedModel(""))
            XCTAssertFalse(request.matchesSelectedModel("unrelated-new-choice"))
        }
    }

    func testDeletedOllamaModelCanBePulledAgain() async throws {
        try await Self.withLibrary { fixture in
            fixture.library.configure(fixture.ollama)
            let exactID = fixture.fast.downloadSpec.ollamaModel
            fixture.backend.installedResult = [exactID]
            fixture.library.refresh()
            try await Self.eventually { !fixture.library.checking }
            fixture.library.requestDeletion(fixture.fast)
            fixture.library.confirmDeletion { _ in }
            try await Self.eventually { fixture.library.deletingID == nil }
            XCTAssertNil(fixture.library.installedID(fixture.fast))

            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            XCTAssertEqual(fixture.library.installedID(fixture.fast), exactID)
            XCTAssertEqual(fixture.backend.deletedIDs, [exactID])
            XCTAssertEqual(fixture.backend.calls, ["installed", "delete", "installed", "pull", "installed"])
        }
    }

    func testChangedServerOrInstalledIdentityInvalidatesConfirmation() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            fixture.library.requestDeletion(fixture.fast)
            fixture.library.configure(fixture.ollama)
            fixture.library.confirmDeletion { _ in XCTFail("Changed server cannot confirm the old request.") }
            XCTAssertNil(fixture.library.pendingDeletion)
            XCTAssertTrue(fixture.backend.deletedIDs.isEmpty)

            fixture.library.configure(fixture.lmStudio)
            try await fixture.installFast()
            fixture.library.requestDeletion(fixture.fast)
            fixture.backend.installedResult = ["qwen2.5-1.5b-instruct"]
            fixture.library.refresh()
            try await Self.eventually { !fixture.library.checking }
            fixture.library.confirmDeletion { _ in XCTFail("Another installed ID cannot replace the confirmed target.") }
            XCTAssertTrue(fixture.backend.deletedIDs.isEmpty)
            XCTAssertNil(fixture.library.pendingDeletion)
            XCTAssertTrue(fixture.library.status.contains("model library changed"))
        }
    }

    func testFailedDeletionPreservesInstalledModelSavedJobAliasAndProgress() async throws {
        try await Self.withLibrary { fixture in
            fixture.backend.startResult = DownloadUpdate(progress: ModelDownloadProgress(status: "Paused", completedBytes: 5, totalBytes: 10), jobID: "saved-job", isPaused: true)
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            try await fixture.installFast()
            fixture.backend.prepareHandler = { _, _ in "saved-instance" }
            fixture.library.use(fixture.fast) { _ in }
            try await Self.eventually { fixture.library.preparingID == nil }
            let savedSelections = fixture.library.selectedInstances
            let savedJobs = fixture.library.savedJobs
            let oldProgress = fixture.library.progress[fixture.fast.id]
            fixture.backend.deleteHandler = { _, _, _ in throw ModelDownloadError.connectionFailed }
            fixture.library.requestDeletion(fixture.fast)
            fixture.library.confirmDeletion { _ in XCTFail("Failure must not clear the active model.") }
            try await Self.eventually { fixture.library.deletingID == nil }

            XCTAssertEqual(fixture.library.installedIDs, [fixture.lmFastID])
            XCTAssertEqual(fixture.library.savedJobs, savedJobs)
            XCTAssertEqual(fixture.library.selectedInstances, savedSelections)
            XCTAssertEqual(fixture.library.progress[fixture.fast.id], oldProgress)
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], ModelDownloadError.connectionFailed.localizedDescription)
            XCTAssertEqual(fixture.backend.calls.last, "delete", "Failure must not pretend deletion succeeded by refreshing.")
            XCTAssertFalse(fixture.library.isBusy)
        }
    }

    func testRefreshFailureAfterDeletionReportsSuccessfulDeletionAndAllowsDownload() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            fixture.backend.installedHandler = { _ in throw ModelDownloadError.connectionFailed }
            var callbacks = 0
            fixture.library.requestDeletion(fixture.fast)
            fixture.library.confirmDeletion { _ in callbacks += 1 }
            try await Self.eventually { fixture.library.deletingID == nil }
            XCTAssertEqual(callbacks, 1)
            XCTAssertNil(fixture.library.installedID(fixture.fast))
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], "Deleted. You can download Fast again.")
            XCTAssertTrue(fixture.library.status.contains("was deleted, but the model list could not refresh"))
            XCTAssertFalse(fixture.library.isBusy)
        }
    }

    func testDeletionBlocksConcurrentMutationsAndDuplicateConfirmation() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            let pending = LibrarySuspension<Void>()
            fixture.backend.deleteHandler = { _, _, _ in try await pending.wait(); return [] }
            var callbacks = 0
            fixture.library.requestDeletion(fixture.fast)
            fixture.library.confirmDeletion { _ in callbacks += 1 }
            fixture.library.confirmDeletion { _ in XCTFail("A confirmation is single use.") }
            try await Self.eventually { pending.isWaiting }
            fixture.library.download(fixture.pro)
            fixture.library.resume(fixture.fast)
            fixture.library.use(fixture.fast) { _ in XCTFail("Preparation must wait for deletion.") }
            fixture.library.refresh()
            fixture.library.requestDeletion(fixture.fast)
            XCTAssertTrue(fixture.library.isBusy)
            XCTAssertNil(fixture.library.pendingDeletion)
            XCTAssertEqual(fixture.backend.calls, ["installed", "delete"])
            pending.succeed(())
            try await Self.eventually { fixture.library.deletingID == nil }
            XCTAssertEqual(callbacks, 1)
            XCTAssertFalse(fixture.library.isBusy)
        }
    }

    func testRefreshStartedBeforeDeletionCannotRestoreDeletedModel() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            let oldRefresh = LibrarySuspension<[String]>()
            var requests = 0
            fixture.backend.installedHandler = { _ in
                requests += 1
                if requests == 1 { return try await oldRefresh.wait() }
                return []
            }
            fixture.library.refresh()
            try await Self.eventually { oldRefresh.isWaiting }
            fixture.library.requestDeletion(fixture.fast)
            fixture.library.confirmDeletion { _ in }
            try await Self.eventually { fixture.library.deletingID == nil }
            oldRefresh.succeed([fixture.lmFastID])
            try await Self.eventually { fixture.backend.completedInstalled == 3 }
            await Task.yield()
            XCTAssertTrue(fixture.library.installedIDs.isEmpty)
            XCTAssertFalse(fixture.library.checking)
            XCTAssertTrue(fixture.library.status.contains("was deleted"))
        }
    }

    func testChangingProviderDuringDeletionPreservesNewContextAndCleansOldMetadata() async throws {
        try await Self.withLibrary { fixture in
            fixture.backend.startResult = DownloadUpdate(progress: ModelDownloadProgress(status: "Paused"), jobID: "old-server-job", isPaused: true)
            fixture.library.download(fixture.fast)
            try await Self.eventually { fixture.library.activeDownloadID == nil }
            try await fixture.installFast()
            fixture.backend.prepareHandler = { _, _ in "old-server-instance" }
            fixture.library.use(fixture.fast) { _ in }
            try await Self.eventually { fixture.library.preparingID == nil }
            let pending = LibrarySuspension<Void>()
            fixture.backend.deleteHandler = { _, _, _ in try await pending.wait(); return [] }
            fixture.library.requestDeletion(fixture.fast)
            fixture.library.confirmDeletion { _ in XCTFail("An old server must not clear the new server's active model.") }
            try await Self.eventually { pending.isWaiting }

            fixture.library.configure(fixture.ollama)
            fixture.library.refresh()
            fixture.library.download(fixture.pro)
            XCTAssertTrue(fixture.library.isBusy, "Changing the visible server cannot allow overlapping model mutations.")
            let newStatus = fixture.library.status
            pending.succeed(())
            try await Self.eventually { fixture.library.deletingID == nil }
            XCTAssertEqual(fixture.backend.deleteConfigurations, [fixture.lmStudio])
            XCTAssertEqual(fixture.library.configuration, fixture.ollama)
            XCTAssertTrue(fixture.library.installedIDs.isEmpty)
            XCTAssertTrue(fixture.library.cardMessages.isEmpty)
            XCTAssertEqual(fixture.library.status, newStatus)
            XCTAssertTrue(fixture.library.savedJobs.isEmpty)
            XCTAssertTrue(fixture.library.selectedInstances.isEmpty)
        }
    }

    func testDeletedScopeMetadataDoesNotRemoveOtherModelsServersOrExactInstallations() async throws {
        try await Self.withLibrary { fixture in
            let otherServer = "http://127.0.0.1:9999"
            let jobs = [
                SavedModelDownload(catalogID: fixture.fast.id, provider: .lmStudio, baseURL: fixture.lmStudio.baseURL, jobID: "deleted"),
                SavedModelDownload(catalogID: fixture.pro.id, provider: .lmStudio, baseURL: fixture.lmStudio.baseURL, jobID: "pro"),
                SavedModelDownload(catalogID: fixture.fast.id, provider: .lmStudio, baseURL: otherServer, jobID: "other-server")
            ]
            let aliases = [
                SavedModelSelection(catalogID: fixture.fast.id, provider: .lmStudio, baseURL: fixture.lmStudio.baseURL, instanceID: "deleted-alias", installedModelID: fixture.lmFastID),
                SavedModelSelection(catalogID: fixture.fast.id, provider: .lmStudio, baseURL: fixture.lmStudio.baseURL, instanceID: "different-installation", installedModelID: "qwen2.5-1.5b-instruct"),
                SavedModelSelection(catalogID: fixture.fast.id, provider: .lmStudio, baseURL: otherServer, instanceID: "other-server-alias"),
                SavedModelSelection(catalogID: fixture.pro.id, provider: .lmStudio, baseURL: fixture.lmStudio.baseURL, instanceID: "pro-alias")
            ]
            fixture.defaults.set(try JSONEncoder().encode(jobs), forKey: "modelDownloadJobs")
            fixture.defaults.set(try JSONEncoder().encode(aliases), forKey: "modelSelectedInstances")
            let library = ModelLibrary(defaults: fixture.defaults, backend: fixture.backend)
            library.configure(fixture.lmStudio)
            fixture.backend.installedResult = [fixture.lmFastID, "qwen2.5-7b-instruct"]
            library.refresh()
            try await Self.eventually { !library.checking }
            library.requestDeletion(fixture.fast)
            let request = try XCTUnwrap(library.pendingDeletion)
            XCTAssertEqual(request.selectedInstanceIDs, ["deleted-alias"])
            library.confirmDeletion { _ in }
            try await Self.eventually { library.deletingID == nil }
            XCTAssertEqual(library.savedJobs, Array(jobs.dropFirst()))
            XCTAssertEqual(library.selectedInstances, Array(aliases.dropFirst()))
            XCTAssertEqual(library.installedIDs, ["qwen2.5-7b-instruct"])
        }
    }

    func testLateDeletionCannotClearAnUnrelatedNewModelChoice() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            let pending = LibrarySuspension<Void>()
            fixture.backend.deleteHandler = { _, _, _ in try await pending.wait(); return [] }
            var activeModel = fixture.lmFastID
            fixture.library.requestDeletion(fixture.fast)
            fixture.library.confirmDeletion { request in
                if request.matchesSelectedModel(activeModel) { activeModel = "" }
            }
            try await Self.eventually { pending.isWaiting }
            activeModel = "new-manual-choice"
            fixture.library.configure(LocalAIConfiguration(provider: .lmStudio, baseURL: fixture.lmStudio.baseURL, model: activeModel))
            pending.succeed(())
            try await Self.eventually { fixture.library.deletingID == nil }
            XCTAssertEqual(activeModel, "new-manual-choice")
            XCTAssertEqual(fixture.library.configuration.model, "new-manual-choice")
            XCTAssertTrue(fixture.library.installedIDs.isEmpty)
        }
    }

    func testStoppedStartCannotRestoreSavedJobAfterDeletion() async throws {
        try await Self.withLibrary { fixture in
            try await fixture.installFast()
            let pending = LibrarySuspension<DownloadUpdate>()
            fixture.backend.startHandler = { _, _ in try await pending.wait() }
            fixture.library.download(fixture.fast)
            try await Self.eventually { pending.isWaiting }
            fixture.library.stopChecking()
            fixture.library.requestDeletion(fixture.fast)
            fixture.library.confirmDeletion { _ in }
            try await Self.eventually { fixture.library.deletingID == nil }
            pending.succeed(fixture.complete(jobID: "stale-job"))
            try await Self.eventually { fixture.backend.completedStarts == 1 }
            await Task.yield()
            XCTAssertTrue(fixture.library.savedJobs.isEmpty)
            XCTAssertTrue(fixture.library.installedIDs.isEmpty)
            XCTAssertEqual(fixture.library.cardMessages[fixture.fast.id], "Deleted. You can download Fast again.")
        }
    }

    @MainActor
    private static func withLibrary(_ body: @MainActor (LibraryFixture) async throws -> Void) async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanup() }
        try await body(fixture)
    }

    @MainActor
    fileprivate static func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("The expected asynchronous state was not reached", file: file, line: line)
        throw LibraryTestFailure.timeout
    }
}

private enum LibraryTestFailure: Error { case timeout }

/// Explicit continuations exercise stale responses even when a backend ignores cancellation.
@MainActor
private final class LibrarySuspension<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    var isWaiting: Bool { continuation != nil }
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func succeed(_ value: Value) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}

@MainActor
private final class LibraryFixture {
    let suite = "EnglishCorrect.ModelLibraryTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let backend = LibraryBackendStub()
    let library: ModelLibrary
    let fast = ModelCatalog.recommendations[0]
    let pro = ModelCatalog.recommendations[1]
    let lmFastID = "Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf"
    let lmStudio = LocalAIConfiguration(provider: .lmStudio, baseURL: "http://127.0.0.1:1234", model: "current-model")
    let ollama = LocalAIConfiguration(provider: .ollama, baseURL: "http://127.0.0.1:11434", model: "current-model")

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        library = ModelLibrary(defaults: defaults, backend: backend, pollingNanoseconds: 0)
        library.configure(lmStudio)
    }
    func cleanup() {
        library.stopChecking()
        defaults.removePersistentDomain(forName: suite)
    }
    func installFast() async throws {
        backend.installedResult = [lmFastID]
        library.refresh()
        try await ModelLibraryTests.eventually { !self.library.checking }
    }
    func complete(jobID: String? = nil) -> DownloadUpdate {
        DownloadUpdate(progress: ModelDownloadProgress(status: "Downloaded"), jobID: jobID, isComplete: true)
    }
}

@MainActor
private final class LibraryBackendStub: ModelLibraryBackend {
    typealias Progress = @Sendable (ModelDownloadProgress) async -> Void
    var calls: [String] = []
    var preparedIDs: [String] = []
    var polledIDs: [String] = []
    var completedPreparations = 0
    var completedInstalled = 0
    var completedPulls = 0
    var completedStarts = 0
    var completedDeletions = 0
    var deletedIDs: [String] = []
    var deleteConfigurations: [LocalAIConfiguration] = []
    var installedResult: [String] = []
    var startResult = DownloadUpdate(progress: ModelDownloadProgress(status: "Downloaded"), isComplete: true)
    var pollResult = DownloadUpdate(progress: ModelDownloadProgress(status: "Downloaded"), isComplete: true)
    var installedHandler: ((LocalAIConfiguration) async throws -> [String])?
    var startHandler: ((DownloadSpec, LocalAIConfiguration) async throws -> DownloadUpdate)?
    var pollHandler: ((String, LocalAIConfiguration) async throws -> DownloadUpdate)?
    var pullHandler: ((DownloadSpec, LocalAIConfiguration, @escaping Progress) async throws -> Void)?
    var prepareHandler: ((String, LocalAIConfiguration) async throws -> String)?
    var deleteHandler: ((String, DownloadSpec, LocalAIConfiguration) async throws -> [String])?

    func installed(_ config: LocalAIConfiguration) async throws -> [String] {
        calls.append("installed")
        defer { completedInstalled += 1 }
        return try await installedHandler?(config) ?? installedResult
    }
    func start(_ spec: DownloadSpec, config: LocalAIConfiguration) async throws -> DownloadUpdate {
        calls.append("start")
        defer { completedStarts += 1 }
        return try await startHandler?(spec, config) ?? startResult
    }
    func poll(_ jobID: String, config: LocalAIConfiguration) async throws -> DownloadUpdate {
        calls.append("poll")
        polledIDs.append(jobID)
        return try await pollHandler?(jobID, config) ?? pollResult
    }
    func pull(_ spec: DownloadSpec, config: LocalAIConfiguration, progress: @escaping Progress) async throws {
        calls.append("pull")
        defer { completedPulls += 1 }
        try await pullHandler?(spec, config, progress)
    }
    func prepare(_ id: String, config: LocalAIConfiguration) async throws -> String {
        calls.append("prepare")
        preparedIDs.append(id)
        defer { completedPreparations += 1 }
        return try await prepareHandler?(id, config) ?? id
    }
    func delete(_ id: String, spec: DownloadSpec, config: LocalAIConfiguration) async throws -> [String] {
        calls.append("delete")
        deletedIDs.append(id)
        deleteConfigurations.append(config)
        defer { completedDeletions += 1 }
        return try await deleteHandler?(id, spec, config) ?? [id]
    }
}
