import XCTest
@testable import EnglishCorrectCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ModelDownloadClientTests: XCTestCase {
    private func config(_ provider: LocalProvider = .lmStudio, address: String? = nil) -> LocalAIConfiguration {
        LocalAIConfiguration(provider: provider, baseURL: address ?? provider.defaultBaseURL, model: "unused-user-model")
    }
    private func spec(repository: String = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF", quantization: String = "Q4_K_M", ollama: String = "qwen2.5:1.5b-instruct-q4_K_M") -> DownloadSpec {
        DownloadSpec(catalogID: "fast", lmStudioRepository: repository, quantization: quantization, ollamaModel: ollama)
    }
    private func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func response(_ request: URLRequest, code: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }
    private func deletionPrelude(_ request: URLRequest, identifiers: [String] = ["qwen:tag"]) throws -> (Data, HTTPURLResponse)? {
        if request.url?.path == "/api/tags" {
            return (try data(["models": identifiers.map { ["name": $0] }]), response(request))
        }
        if request.url?.path == "/api/generate" {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            return (try data(["model": body["model"]!, "response": "", "done": true, "done_reason": "unload"]), response(request))
        }
        return nil
    }

    func testDownloadSpecsRestrictRepositoryAndLocalModelTag() throws {
        XCTAssertNoThrow(try ModelDownloadClient.validate(spec()))
        XCTAssertNoThrow(try ModelDownloadClient.validate(spec(repository: "https://hf.co/Qwen/Qwen2.5-7B-Instruct-GGUF")))
        for url in ["http://huggingface.co/Qwen/model", "https://evil.example/Qwen/model", "https://huggingface.co.evil.example/Qwen/model", "https://user@huggingface.co/Qwen/model", "https://huggingface.co:443/Qwen/model", "https://huggingface.co/Qwen/model?download=true", "https://huggingface.co/Qwen/model#x", "https://huggingface.co/Qwen/model/resolve/main/weights.gguf", "https://huggingface.co/Qwen/%2E%2E", "https://huggingface.co/Qwen/model/"] {
            XCTAssertThrowsError(try ModelDownloadClient.validate(spec(repository: url)), url) { XCTAssertEqual($0 as? ModelDownloadError, .invalidSpecification) }
        }
        for tag in ["qwen2.5", "qwen2.5:cloud", "qwen2.5:7b-cloud", "qwen2.5:CLOUD", "https://server/model", "registry.example/model:tag", "qwen2.5:7b\n", "../qwen:7b", "qwen:tag with spaces"] {
            XCTAssertThrowsError(try ModelDownloadClient.validate(spec(ollama: tag)), tag)
        }
        XCTAssertThrowsError(try ModelDownloadClient.validate(spec(quantization: "Q4_K_M;exec")))
    }

    func testLMStudioStartUsesOnlyModelMetadataOnLoopback() async throws {
        let recorder = DownloadRecorder()
        let payload = try data(["job_id": "job_abc123", "status": "downloading", "total_size_bytes": 1_120_000_000])
        let client = ModelDownloadClient(configuration: config(address: "http://localhost:1234/v1")) { request in
            await recorder.record(request)
            return (payload, self.response(request))
        }
        let update = try await client.startLMStudio(spec())
        XCTAssertFalse(update.isComplete)
        XCTAssertEqual(update.jobID, "job_abc123")
        XCTAssertEqual(update.progress.totalBytes, 1_120_000_000)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/api/v1/models/download")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["model": spec().lmStudioRepository, "quantization": "Q4_K_M"])
    }

    func testPollingRequiresExactSafeJobIdentity() async throws {
        let recorder = DownloadRecorder()
        let payload = try data(["job_id": "job_abc123", "status": "completed", "downloaded_bytes": 100, "total_size_bytes": 100])
        let client = ModelDownloadClient(configuration: config()) { request in
            await recorder.record(request)
            return (payload, self.response(request))
        }
        let update = try await client.pollLMStudio(jobID: "job_abc123")
        XCTAssertTrue(update.isComplete)
        XCTAssertEqual(update.progress.fraction, 1)
        let requests = await recorder.requests
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/models/download/status/job_abc123")
        XCTAssertNil(requests.first?.httpBody)
        do { _ = try await client.pollLMStudio(jobID: "other_job"); XCTFail("Mismatched job accepted") }
        catch { XCTAssertEqual(error as? ModelDownloadError, .invalidResponse) }
        for job in ["", "../other", "job/a", "job?x=yes", "job%2Fa", "job\n", String(repeating: "a", count: 129)] {
            do { _ = try await client.pollLMStudio(jobID: job); XCTFail("Unsafe job accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidJobID) }
        }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2)
    }

    func testPausedAndAlreadyDownloadedAreDistinctFromFailure() throws {
        let paused = try ModelDownloadClient.parseLMStudio(data(["job_id": "job_1", "status": "paused", "downloaded_bytes": 20, "total_size_bytes": 100]))
        XCTAssertTrue(paused.isPaused)
        XCTAssertFalse(paused.isComplete)
        XCTAssertEqual(paused.progress.fraction, 0.2)
        let ready = try ModelDownloadClient.parseLMStudio(data(["status": "already_downloaded"]))
        XCTAssertTrue(ready.isComplete)
        XCTAssertNil(ready.jobID)
        XCTAssertFalse(ready.isPaused)
        XCTAssertThrowsError(try ModelDownloadClient.parseLMStudio(data(["job_id": "job_1", "status": "failed"]))) { XCTAssertEqual($0 as? ModelDownloadError, .downloadFailed) }
        XCTAssertThrowsError(try ModelDownloadClient.parseLMStudio(data(["status": "failed", "error": ["message": "No space left on device"]]))) { XCTAssertEqual($0 as? ModelDownloadError, .insufficientStorage) }
        XCTAssertThrowsError(try ModelDownloadClient.parseLMStudio(data(["status": "failed", "message": "disk full"]))) { XCTAssertEqual($0 as? ModelDownloadError, .insufficientStorage) }
    }

    func testMalformedStatusesAndCountsCannotImplyCompletion() throws {
        for payload: Any in [[], ["status": "success"], ["status": "queued", "job_id": "job_1"], ["status": "downloading"], ["status": "completed", "job_id": 5], ["status": "completed", "job_id": "../job"]] {
            XCTAssertThrowsError(try ModelDownloadClient.parseLMStudio(data(payload))) { XCTAssertEqual($0 as? ModelDownloadError, .invalidResponse) }
        }
        for bad: Any in [-1, 0.5, true, "123", NSNumber(value: UInt64.max)] {
            XCTAssertThrowsError(try ModelDownloadClient.parseLMStudio(data(["job_id": "job_1", "status": "downloading", "downloaded_bytes": bad])))
            XCTAssertThrowsError(try ModelDownloadClient.parseOllamaLine(data(["status": "pulling manifest", "total": bad])))
        }
        XCTAssertThrowsError(try ModelDownloadClient.parseLMStudio(data(["job_id": "job_1", "status": "downloading", "downloaded_bytes": 101, "total_size_bytes": 100])))
        let empty = try ModelDownloadClient.parseLMStudio(data(["job_id": "job_1", "status": "downloading", "downloaded_bytes": 0, "total_size_bytes": 0]))
        XCTAssertNil(empty.progress.fraction)
        XCTAssertNil(ModelDownloadProgress(status: "Test", completedBytes: -1, totalBytes: 100).fraction)
        XCTAssertNil(ModelDownloadProgress(status: "Test", completedBytes: 101, totalBytes: 100).fraction)
        XCTAssertEqual(ModelDownloadProgress(status: "Test", completedBytes: Int64.max, totalBytes: Int64.max).fraction, 1)
    }

    func testOllamaLineParsingKeepsLayerProgressAndErrors() throws {
        let update = try ModelDownloadClient.parseOllamaLine(data(["status": "pulling abcdef012345", "digest": "sha256:abcdef012345", "total": 100, "completed": 42]))
        XCTAssertEqual(update.progress.status, "Downloading model file")
        XCTAssertEqual(update.progress.fraction, 0.42)
        XCTAssertFalse(update.isComplete)
        for status in ["pulling manifest", "verifying sha256 digest", "writing manifest", "removing any unused layers"] {
            XCTAssertFalse(try ModelDownloadClient.parseOllamaLine(data(["status": status])).isComplete)
        }
        XCTAssertTrue(try ModelDownloadClient.parseOllamaLine(data(["status": "success"])).isComplete)
        XCTAssertThrowsError(try ModelDownloadClient.parseOllamaLine(data(["status": "completed"])))
        XCTAssertThrowsError(try ModelDownloadClient.parseOllamaLine(data(["error": "untrusted raw output"]))) { XCTAssertEqual($0 as? ModelDownloadError, .downloadFailed) }
        XCTAssertThrowsError(try ModelDownloadClient.parseOllamaLine(data(["error": "write failed: no space left on device"]))) { XCTAssertEqual($0 as? ModelDownloadError, .insufficientStorage) }
    }

    func testOllamaPullStreamsAndRequiresFinalSuccess() async throws {
        let recorder = DownloadRecorder()
        let progress = DownloadProgressRecorder()
        let lines = try [data(["status": "pulling manifest"]), data(["status": "pulling abcdef012345", "total": 100, "completed": 50]), data(["status": "success"])]
        let client = ModelDownloadClient(configuration: config(.ollama), transport: { _ in XCTFail("Used buffered transport"); throw ModelDownloadError.invalidResponse }, streamTransport: { request, receive in
            await recorder.record(request)
            try await receive(.response(self.response(request)))
            for line in lines { try await receive(.line(line)) }
        })
        try await client.pullOllama(spec()) { await progress.append($0) }
        let updates = await progress.values
        XCTAssertEqual(updates.count, 3)
        XCTAssertEqual(updates[1].fraction, 0.5)
        XCTAssertEqual(updates.last?.status, "Downloaded")
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/pull")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, spec().ollamaModel)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(Set(body.keys), ["model", "stream"])
    }

    func testMissingSuccessStreamErrorAndInvalidEventOrderingFail() async throws {
        let manifest = try data(["status": "pulling manifest"])
        let success = try data(["status": "success"])
        let failure = try data(["error": "network interruption"])
        for mode in 0..<5 {
            let client = ModelDownloadClient(configuration: config(.ollama), transport: { _ in throw ModelDownloadError.invalidResponse }, streamTransport: { request, receive in
                if mode != 3 { try await receive(.response(self.response(request))) }
                try await receive(.line(manifest))
                if mode == 1 { try await receive(.line(failure)) }
                if mode == 2 { try await receive(.response(self.response(request))) }
                if mode == 4 {
                    try await receive(.line(success))
                    try await receive(.line(manifest))
                }
            })
            do { try await client.pullOllama(spec()) { _ in }; XCTFail("Incomplete/invalid stream accepted") }
            catch {
                let expected: ModelDownloadError = mode == 0 ? .incompleteDownload : mode == 1 ? .downloadFailed : .invalidResponse
                XCTAssertEqual(error as? ModelDownloadError, expected)
            }
        }
    }

    func testRemoteEndpointsFailBeforeAnyTransport() async throws {
        for provider in [LocalProvider.lmStudio, .ollama] {
            for address in ["https://localhost", "http://192.168.1.5", "http://localhost.evil.example", "http://user@localhost", "http://localhost?query=secret"] {
                let recorder = DownloadRecorder()
                let client = ModelDownloadClient(configuration: config(provider, address: address), transport: { request in
                    await recorder.record(request)
                    throw ModelDownloadError.invalidResponse
                }, streamTransport: { request, _ in
                    await recorder.record(request)
                    throw ModelDownloadError.invalidResponse
                })
                do {
                    if provider == .lmStudio { _ = try await client.startLMStudio(spec()) }
                    else { try await client.pullOllama(spec()) { _ in } }
                    XCTFail("Remote server accepted")
                } catch { XCTAssertEqual(error as? LocalAIError, .invalidAddress) }
                let count = await recorder.requests.count
                XCTAssertEqual(count, 0)
            }
        }
    }

    func testHTTPFailuresAndRedirectsAreActionable() async throws {
        for (status, expected): (Int, ModelDownloadError) in [(301, .redirectBlocked), (307, .redirectBlocked), (401, .authenticationRequired), (403, .authenticationRequired), (404, .endpointUnavailable), (405, .endpointUnavailable), (507, .insufficientStorage), (503, .serverError(503))] {
            let client = ModelDownloadClient(configuration: config(), transport: { request in (Data(), self.response(request, code: status)) })
            do { _ = try await client.startLMStudio(spec()); XCTFail("HTTP failure accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, expected) }
            let stream = ModelDownloadClient(configuration: config(.ollama), transport: { _ in throw ModelDownloadError.invalidResponse }, streamTransport: { request, receive in
                try await receive(.response(self.response(request, code: status)))
                XCTFail("Stream was allowed after failing response")
            })
            do { try await stream.pullOllama(spec()) { _ in XCTFail("Invalid progress") }; XCTFail("Stream failure accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, expected) }
        }
    }

    func testNetworkFailuresPreserveCancellation() async throws {
        for code: URLError.Code in [.cancelled, .timedOut, .cannotConnectToHost] {
            let client = ModelDownloadClient(configuration: config(), transport: { _ in throw URLError(code) })
            do { _ = try await client.startLMStudio(spec()); XCTFail("Expected network failure") }
            catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ModelDownloadError, code == .timedOut ? .timedOut : .connectionFailed) }
            }
            let stream = ModelDownloadClient(configuration: config(.ollama), transport: { _ in throw URLError(code) }, streamTransport: { _, _ in throw URLError(code) })
            do { try await stream.pullOllama(spec()) { _ in }; XCTFail("Expected stream failure") }
            catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ModelDownloadError, code == .timedOut ? .timedOut : .connectionFailed) }
            }
        }
    }

    func testCancellationStopsBeforeAdditionalProgress() async throws {
        let progress = DownloadProgressRecorder()
        let received = expectation(description: "Streaming started")
        let manifest = try data(["status": "pulling manifest"])
        let client = ModelDownloadClient(configuration: config(.ollama), transport: { _ in throw ModelDownloadError.invalidResponse }, streamTransport: { request, receive in
            try await receive(.response(self.response(request)))
            try await receive(.line(manifest))
            received.fulfill()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            try await receive(.line(manifest))
        })
        let task = Task { try await client.pullOllama(self.spec()) { await progress.append($0) } }
        await fulfillment(of: [received], timeout: 1)
        task.cancel()
        do { try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await progress.values.count
        XCTAssertEqual(count, 1)
    }

    func testLineFramingHandlesCRLFAndBoundsEachLine() throws {
        var buffer = DownloadLineBuffer()
        var lines: [Data] = []
        for byte in Data("\n{\"status\":\"pulling manifest\"}\r\n{\"status\":\"success\"}".utf8) {
            if let line = try buffer.append(byte) { lines.append(line) }
        }
        if let final = buffer.finish() { lines.append(final) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(try ModelDownloadClient.parseOllamaLine(lines[0]).isComplete)
        XCTAssertTrue(try ModelDownloadClient.parseOllamaLine(lines[1]).isComplete)
        XCTAssertNil(buffer.finish())
        for _ in 0..<ModelDownloadClient.maximumStatusBytes { _ = try buffer.append(65) }
        XCTAssertThrowsError(try buffer.append(65)) { XCTAssertEqual($0 as? ModelDownloadError, .responseTooLong) }
        XCTAssertEqual(try buffer.append(10)?.count, ModelDownloadClient.maximumStatusBytes)
        XCTAssertNil(buffer.finish())
        XCTAssertThrowsError(try ModelDownloadClient.parseLMStudio(Data(repeating: 65, count: ModelDownloadClient.maximumStatusBytes + 1))) { XCTAssertEqual($0 as? ModelDownloadError, .responseTooLong) }
    }

    func testPrepareLMStudioLoadsWithBoundedContextAndReturnsInstanceID() async throws {
        let recorder = DownloadRecorder()
        let payload = try data(["type": "llm", "status": "loaded", "instance_id": "qwen2.5-1.5b-instruct"])
        let client = ModelDownloadClient(configuration: config()) { request in
            await recorder.record(request)
            return (payload, self.response(request))
        }
        let instance = try await client.prepareModel("qwen/qwen2.5-1.5b-instruct")
        XCTAssertEqual(instance, "qwen2.5-1.5b-instruct")
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/models/load")
        XCTAssertEqual(request.timeoutInterval, 120)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen/qwen2.5-1.5b-instruct")
        XCTAssertEqual(body["context_length"] as? Int, 8192)
    }

    func testPrepareModelRejectsCloudOrEmptyIDsAndInvalidLoadedResponses() async throws {
        for provider in [LocalProvider.lmStudio, .ollama] {
            let client = ModelDownloadClient(configuration: config(provider)) { _ in XCTFail("Invalid ID reached transport"); throw ModelDownloadError.invalidResponse }
            for identifier in ["", " \n", "qwen:cloud", "gpt-oss:20b-cloud", "name\n", String(repeating: "a", count: 513)] {
                do { _ = try await client.prepareModel(identifier); XCTFail("Invalid model accepted") }
                catch { XCTAssertEqual(error as? ModelDownloadError, .invalidSpecification) }
            }
        }
        for payload: [String: Any] in [["type": "embedding", "status": "loaded", "instance_id": "vectors"], ["type": "llm", "status": "loading", "instance_id": "qwen"], ["type": "llm", "status": "loaded", "instance_id": ""], ["type": "llm", "status": "loaded"]] {
            let encoded = try data(payload)
            let client = ModelDownloadClient(configuration: config()) { request in (encoded, self.response(request)) }
            do { _ = try await client.prepareModel("qwen"); XCTFail("Malformed response accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidResponse) }
        }
        let ollama = ModelDownloadClient(configuration: config(.ollama)) { _ in XCTFail("Ollama should load lazily"); throw ModelDownloadError.invalidResponse }
        let name = try await ollama.prepareModel("qwen2.5:1.5b-instruct-q4_K_M")
        XCTAssertEqual(name, "qwen2.5:1.5b-instruct-q4_K_M")
    }

    func testDeleteOllamaUsesExactTaggedModelAndEmptySuccessResponse() async throws {
        let recorder = DownloadRecorder()
        let client = ModelDownloadClient(configuration: config(.ollama, address: "http://localhost:11434/api")) { request in
            await recorder.record(request)
            if let prelude = try self.deletionPrelude(request, identifiers: ["qwen2.5:1.5b-instruct-q4_K_M", "my_org/MyModel:Q4_0", "llama3:latest"]) { return prelude }
            return (Data(), self.response(request))
        }
        for identifier in ["qwen2.5:1.5b-instruct-q4_K_M", "my_org/MyModel:Q4_0", "llama3:latest"] {
            try await client.deleteOllamaModel(identifier)
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.map { $0.url!.path }, Array(repeating: ["/api/tags", "/api/generate", "/api/delete"], count: 3).flatMap { $0 })
        for request in requests where request.url?.path == "/api/generate" {
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["model", "keep_alive", "stream"])
            XCTAssertEqual(body["keep_alive"] as? Int, 0)
            XCTAssertEqual(body["stream"] as? Bool, false)
        }
        for (request, identifier) in zip(requests.filter { $0.httpMethod == "DELETE" }, ["qwen2.5:1.5b-instruct-q4_K_M", "my_org/MyModel:Q4_0", "llama3:latest"]) {
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/delete")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.timeoutInterval, 30)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            XCTAssertEqual(body, ["model": identifier])
        }
    }

    func testDeleteOllamaRejectsUnsafeCloudRemoteAndImplicitModelIDsBeforeTransport() async throws {
        let client = ModelDownloadClient(configuration: config(.ollama)) { _ in
            XCTFail("Invalid model reached transport")
            throw ModelDownloadError.invalidResponse
        }
        for identifier in ["", " ", "qwen", "qwen:tag\n", " qwen:tag", "qwen:tag ", "qwen:ta g", "qwen:ta\tg", "qwen:tag\0", "qwen:cloud", "qwen:CLOUD", "gpt-oss:20b-cloud", "cloud/model:tag", "https://server/model:tag", "http://localhost/model:tag", "registry.example/model:tag", "registry.example:5000/model:tag", "registry/namespace/model:tag", "../qwen:tag", "qwen/../other:tag", "/qwen:tag", "qwen\\other:tag", "qwen:*", "qwen:tag?query=yes", "qwen:tag#part", "qwen:tag%2Fother", "qwen:tag;delete", "qwen:tag@digest", "qwen::tag", "qwen:タグ", String(repeating: "a", count: 513) + ":tag"] {
            do { try await client.deleteOllamaModel(identifier); XCTFail("Unsafe identifier accepted: \(identifier)") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidSpecification, identifier) }
        }
        let otherProvider = ModelDownloadClient(configuration: config(.lmStudio)) { _ in
            XCTFail("Wrong provider reached transport")
            throw ModelDownloadError.invalidResponse
        }
        do { try await otherProvider.deleteOllamaModel("qwen:tag"); XCTFail("Wrong provider accepted") }
        catch { XCTAssertEqual(error as? ModelDownloadError, .wrongProvider) }
    }

    func testDeleteOllamaRejectsNonLoopbackOrAmbiguousEndpoints() async throws {
        for address in ["https://localhost", "http://192.168.1.5", "http://localhost.evil.example", "http://user@localhost", "http://localhost?query=secret", "http://localhost/api/other", "http://localhost/#fragment"] {
            let client = ModelDownloadClient(configuration: config(.ollama, address: address)) { _ in
                XCTFail("Invalid address reached transport")
                throw ModelDownloadError.invalidResponse
            }
            do { try await client.deleteOllamaModel("qwen:tag"); XCTFail("Invalid endpoint accepted") }
            catch { XCTAssertEqual(error as? LocalAIError, .invalidAddress, address) }
        }
    }

    func testDeleteOllamaHandlesBodiesAndRequiresFinal200Status() async throws {
        let emptyObject = ModelDownloadClient(configuration: config(.ollama)) { request in
            if let prelude = try self.deletionPrelude(request) { return prelude }
            return (Data("{}".utf8), self.response(request))
        }
        try await emptyObject.deleteOllamaModel("qwen:tag")
        for body in ["[]", "null", "true", " ", "invalid", "{", "{\"status\":\"success\"}", "{\"status\":\"pending\"}", "{\"unexpected\":1}"] {
            let client = ModelDownloadClient(configuration: config(.ollama)) { request in
                if let prelude = try self.deletionPrelude(request) { return prelude }
                return (Data(body.utf8), self.response(request))
            }
            do { try await client.deleteOllamaModel("qwen:tag"); XCTFail("Unexpected body accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidResponse, body) }
        }
        for body in ["{\"error\":\"failed\"}", "{\"error\":null}", "{\"error\":{\"message\":\"failed\"}}"] {
            let client = ModelDownloadClient(configuration: config(.ollama)) { request in
                if let prelude = try self.deletionPrelude(request) { return prelude }
                return (Data(body.utf8), self.response(request))
            }
            do { try await client.deleteOllamaModel("qwen:tag"); XCTFail("Error body accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .deletionFailed) }
        }
        for status in [201, 202, 204, 206] {
            let client = ModelDownloadClient(configuration: config(.ollama)) { request in
                if let prelude = try self.deletionPrelude(request) { return prelude }
                return (Data(), self.response(request, code: status))
            }
            do { try await client.deleteOllamaModel("qwen:tag"); XCTFail("Unexpected success status accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidResponse) }
        }
    }

    func testDeleteOllamaHTTPFailuresAndRedirectsNeverRetry() async throws {
        for (status, expected): (Int, ModelDownloadError) in [(301, .redirectBlocked), (307, .redirectBlocked), (308, .redirectBlocked), (401, .authenticationRequired), (403, .authenticationRequired), (404, .endpointUnavailable), (405, .endpointUnavailable), (500, .serverError(500)), (503, .serverError(503))] {
            let recorder = DownloadRecorder()
            let client = ModelDownloadClient(configuration: config(.ollama)) { request in
                if let prelude = try self.deletionPrelude(request) { return prelude }
                await recorder.record(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Location": "https://remote.example/api/delete"])!
                return (Data("{\"error\":\"failed\"}".utf8), response)
            }
            do { try await client.deleteOllamaModel("qwen:tag"); XCTFail("HTTP failure accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, expected) }
            let requestCount = await recorder.requests.count
            XCTAssertEqual(requestCount, 1)
        }
        let oversized = ModelDownloadClient(configuration: config(.ollama)) { request in
            if let prelude = try self.deletionPrelude(request) { return prelude }
            return (Data(repeating: 32, count: ModelDownloadClient.maximumStatusBytes + 1), self.response(request))
        }
        do { try await oversized.deleteOllamaModel("qwen:tag"); XCTFail("Oversized response accepted") }
        catch { XCTAssertEqual(error as? ModelDownloadError, .responseTooLong) }
    }

    func testDeleteOllamaNetworkFailuresPreserveCancellationWithoutRetry() async throws {
        for code: URLError.Code in [.cancelled, .timedOut, .cannotConnectToHost] {
            let recorder = DownloadRecorder()
            let client = ModelDownloadClient(configuration: config(.ollama)) { request in
                await recorder.record(request)
                throw URLError(code)
            }
            do { try await client.deleteOllamaModel("qwen:tag"); XCTFail("Expected network failure") }
            catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ModelDownloadError, code == .timedOut ? .timedOut : .connectionFailed) }
            }
            let requestCount = await recorder.requests.count
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testDeleteOllamaCancellationBeforeAndDuringRequest() async throws {
        let untouched = ModelDownloadClient(configuration: config(.ollama)) { _ in
            XCTFail("Cancelled deletion reached transport")
            throw ModelDownloadError.invalidResponse
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await untouched.deleteOllamaModel("qwen:tag")
        }
        do { try await cancelled.value; XCTFail("Pre-request cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }

        let started = expectation(description: "Deletion started")
        let recorder = DownloadRecorder()
        let client = ModelDownloadClient(configuration: config(.ollama)) { request in
            await recorder.record(request)
            started.fulfill()
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return (Data(), self.response(request))
        }
        let task = Task { try await client.deleteOllamaModel("qwen:tag") }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { try await task.value; XCTFail("In-flight cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    func testDeleteOllamaCancelledTransportCannotReportSuccess() async throws {
        let client = ModelDownloadClient(configuration: config(.ollama)) { request in
            withUnsafeCurrentTask { $0?.cancel() }
            return (Data(), self.response(request))
        }
        let task = Task { try await client.deleteOllamaModel("qwen:tag") }
        do { try await task.value; XCTFail("Cancelled deletion reported success") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testDeleteOllamaRefusesRemoteAliasesAndMissingOrDuplicateInstalledIdentity() async throws {
        for records: [[String: Any]] in [[], [["name": "other:tag"]], [["name": "qwen:tag"], ["name": "qwen:tag"]], [["name": "qwen:tag", "remote_host": "https://ollama.com"]], [["name": "qwen:tag", "remote_model": "cloud-model"]], [["name": "qwen:tag", "remote_host": 1]], [["name": "qwen:tag", "type": "embedding"]]] {
            let payload = try data(["models": records])
            let recorder = DownloadRecorder()
            let client = ModelDownloadClient(configuration: config(.ollama)) { request in
                await recorder.record(request)
                return (payload, self.response(request))
            }
            do { try await client.deleteOllamaModel("qwen:tag"); XCTFail("Unverified installed model accepted") }
            catch { XCTAssertEqual(error as? LocalAIError, .modelUnavailable) }
            let paths = await recorder.requests.map { $0.url!.path }
            XCTAssertEqual(paths, ["/api/tags"])
        }
    }

    func testDeleteOllamaRequiresConfirmedUnloadBeforeDeleting() async throws {
        for payload: [String: Any] in [[:], ["model": "other:tag", "response": "", "done": true, "done_reason": "unload"], ["model": "qwen:tag", "response": "", "done": 1, "done_reason": "unload"], ["model": "qwen:tag", "response": "", "done": false, "done_reason": "unload"], ["model": "qwen:tag", "response": "", "done": true, "done_reason": "load"], ["model": "qwen:tag", "response": "text", "done": true, "done_reason": "unload"], ["model": "qwen:tag", "response": "", "done": true, "done_reason": "unload", "remote_host": "https://remote.example"]] {
            let encoded = try data(payload)
            let recorder = DownloadRecorder()
            let client = ModelDownloadClient(configuration: config(.ollama)) { request in
                await recorder.record(request)
                if request.url?.path == "/api/tags", let response = try self.deletionPrelude(request) { return response }
                return (encoded, self.response(request))
            }
            do { try await client.deleteOllamaModel("qwen:tag"); XCTFail("Unconfirmed unload accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidResponse) }
            let paths = await recorder.requests.map { $0.url!.path }
            XCTAssertEqual(paths, ["/api/tags", "/api/generate"])
        }
    }

    private func lmDeletionRecord(_ instances: [String] = []) -> [String: Any] {
        ["type": "llm", "publisher": "Qwen", "key": "qwen2.5-1.5b-instruct", "format": "gguf", "quantization": ["name": "Q4_K_M"], "loaded_instances": instances.map { ["id": $0] }]
    }

    func testLMStudioDeletionUnloadsExactInstancesAndRechecks() async throws {
        let before = try data(["models": [lmDeletionRecord(["qwen2.5-1.5b-instruct", "qwen2.5-1.5b-instruct:2"])]])
        let after = try data(["models": [lmDeletionRecord()]])
        let queue = DownloadPayloadQueue([before, try data(["instance_id": "qwen2.5-1.5b-instruct"]), try data(["instance_id": "qwen2.5-1.5b-instruct:2"]), after])
        let recorder = DownloadRecorder()
        let client = ModelDownloadClient(configuration: config()) { request in
            await recorder.record(request)
            return (try await queue.next(), self.response(request))
        }
        let unloaded = try await client.unloadLMStudioModelForDeletion("qwen2.5-1.5b-instruct", spec: ModelCatalog.recommendations[0].downloadSpec)
        XCTAssertEqual(unloaded, ["qwen2.5-1.5b-instruct", "qwen2.5-1.5b-instruct:2"])
        let requests = await recorder.requests
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/v1/models", "/api/v1/models/unload", "/api/v1/models/unload", "/api/v1/models"])
        for request in [requests[0], requests[3]] {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
        }
        for (request, instance) in zip(requests[1...2], ["qwen2.5-1.5b-instruct", "qwen2.5-1.5b-instruct:2"]) {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String], ["instance_id": instance])
        }
    }

    func testLMStudioDeletionAcceptsAlreadyUnloadedAndUniqueExplicitQ4Variant() async throws {
        for explicitVariant in [false, true] {
            var record = lmDeletionRecord()
            let identifier: String
            if explicitVariant {
                identifier = "qwen2.5-1.5b-instruct@q4_k_m"
                record["variants"] = [identifier]
                record["selected_variant"] = identifier
                record["quantization"] = NSNull()
            } else { identifier = "qwen2.5-1.5b-instruct" }
            let payload = try data(["models": [record]])
            let recorder = DownloadRecorder()
            let client = ModelDownloadClient(configuration: config()) { request in
                await recorder.record(request)
                return (payload, self.response(request))
            }
            try await client.unloadLMStudioModelForDeletion(identifier, spec: ModelCatalog.recommendations[0].downloadSpec)
            let paths = await recorder.requests.map { $0.url!.path }
            XCTAssertEqual(paths, ["/api/v1/models", "/api/v1/models"])
        }
    }

    func testLMStudioDeletionRejectsUnknownSpecsAndModelsBeforeTransport() async throws {
        let client = ModelDownloadClient(configuration: config()) { _ in XCTFail("Invalid specification reached transport"); throw ModelDownloadError.invalidResponse }
        for identifier in ["", "../qwen2.5-1.5b-instruct", "qwen2.5-7b-instruct", "other/qwen2.5-1.5b-instruct", "qwen2.5-1.5b-instruct:2"] {
            do { try await client.unloadLMStudioModelForDeletion(identifier, spec: ModelCatalog.recommendations[0].downloadSpec); XCTFail("Unknown model accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidSpecification) }
        }
        for changed in [spec(repository: "https://huggingface.co/Someone/Qwen2.5-1.5B-Instruct-GGUF"), spec(quantization: "Q8_0"), spec(ollama: "other:tag")] {
            do { try await client.unloadLMStudioModelForDeletion("qwen2.5-1.5b-instruct", spec: changed); XCTFail("Unknown specification accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidSpecification) }
        }
        let ollama = ModelDownloadClient(configuration: config(.ollama)) { _ in XCTFail("Wrong provider reached transport"); throw ModelDownloadError.invalidResponse }
        do { try await ollama.unloadLMStudioModelForDeletion("qwen2.5-1.5b-instruct", spec: spec()); XCTFail("Wrong provider accepted") }
        catch { XCTAssertEqual(error as? ModelDownloadError, .wrongProvider) }
    }

    func testLMStudioDeletionRejectsAmbiguousUntrustedOrMalformedMetadata() async throws {
        var invalidRecords: [[String: Any]] = []
        for (field, value): (String, Any) in [("publisher", "other"), ("publisher", NSNull()), ("format", "mlx"), ("type", "embedding"), ("quantization", ["name": "Q8_0"]), ("quantization", NSNull()), ("loaded_instances", NSNull()), ("loaded_instances", [["id": "qwen\n"]]), ("loaded_instances", [["id": "a"], ["id": "a"]]), ("loaded_instances", Array(repeating: ["id": "a"], count: 33)), ("variants", ["qwen2.5-1.5b-instruct@q4_k_m", "qwen2.5-1.5b-instruct@q8_0"]), ("variants", ["qwen2.5-7b-instruct@q4_k_m"]), ("remote_host", "https://remote.example")] {
            var record = lmDeletionRecord(["instance"])
            record[field] = value
            invalidRecords.append(record)
        }
        for record in invalidRecords {
            let payload = try data(["models": [record]])
            let recorder = DownloadRecorder()
            let client = ModelDownloadClient(configuration: config()) { request in
                await recorder.record(request)
                return (payload, self.response(request))
            }
            do { try await client.unloadLMStudioModelForDeletion("qwen2.5-1.5b-instruct", spec: spec()); XCTFail("Unsafe metadata accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidResponse) }
            let paths = await recorder.requests.map { $0.url!.path }
            XCTAssertEqual(paths, ["/api/v1/models"])
        }
        for records in [[], [lmDeletionRecord(), lmDeletionRecord()], [lmDeletionRecord(["shared"]), ["key": "other-model", "loaded_instances": [["id": "shared"]]]]] {
            let payload = try data(["models": records])
            let client = ModelDownloadClient(configuration: config()) { request in
                XCTAssertEqual(request.url?.path, "/api/v1/models")
                return (payload, self.response(request))
            }
            do { try await client.unloadLMStudioModelForDeletion("qwen2.5-1.5b-instruct", spec: spec()); XCTFail("Ambiguous metadata accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .invalidResponse) }
        }
    }

    func testLMStudioDeletionStopsWhenUnloadCannotBeConfirmed() async throws {
        let before = try data(["models": [lmDeletionRecord(["instance"])]])
        for result: [String: Any] in [[:], ["instance_id": "other"], ["instance_id": "instance", "extra": true], ["instance_id": "instance", "error": "failed"]] {
            let queue = DownloadPayloadQueue([before, try data(result)])
            let recorder = DownloadRecorder()
            let client = ModelDownloadClient(configuration: config()) { request in
                await recorder.record(request)
                return (try await queue.next(), self.response(request))
            }
            do { try await client.unloadLMStudioModelForDeletion("qwen2.5-1.5b-instruct", spec: spec()); XCTFail("Invalid unload confirmation accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, result["error"] == nil ? .invalidResponse : .deletionFailed) }
            let count = await recorder.requests.count
            XCTAssertEqual(count, 2)
        }
    }

    func testLMStudioDeletionFailsIfExistingOrNewInstanceRemainsWithoutRepeatedUnloading() async throws {
        let before = try data(["models": [lmDeletionRecord(["instance"])]])
        for remaining in ["instance", "new-instance"] {
            let after = try data(["models": [lmDeletionRecord([remaining])]])
            let queue = DownloadPayloadQueue([before, try data(["instance_id": "instance"]), after])
            let recorder = DownloadRecorder()
            let client = ModelDownloadClient(configuration: config()) { request in
                await recorder.record(request)
                return (try await queue.next(), self.response(request))
            }
            do { try await client.unloadLMStudioModelForDeletion("qwen2.5-1.5b-instruct", spec: spec()); XCTFail("Still-loaded model accepted") }
            catch { XCTAssertEqual(error as? ModelDownloadError, .modelInUse) }
            let paths = await recorder.requests.map { $0.url!.path }
            XCTAssertEqual(paths, ["/api/v1/models", "/api/v1/models/unload", "/api/v1/models"])
        }
    }

    func testLMStudioDeletionCancellationStopsFurtherUnloads() async throws {
        let before = try data(["models": [lmDeletionRecord(["first", "second"])]])
        let recorder = DownloadRecorder()
        let client = ModelDownloadClient(configuration: config()) { request in
            await recorder.record(request)
            if request.url?.path == "/api/v1/models" { return (before, self.response(request)) }
            withUnsafeCurrentTask { $0?.cancel() }
            return (try self.data(["instance_id": "first"]), self.response(request))
        }
        let task = Task { try await client.unloadLMStudioModelForDeletion("qwen2.5-1.5b-instruct", spec: self.spec()) }
        do { _ = try await task.value; XCTFail("Cancelled unload reported success") }
        catch { XCTAssertTrue(error is CancellationError) }
        let paths = await recorder.requests.map { $0.url!.path }
        XCTAssertEqual(paths, ["/api/v1/models", "/api/v1/models/unload"])
    }

    func testFreshLMStudioServerNeedsNoDownloadedOrSelectedModelForDiscovery() async throws {
        let recorder = DownloadRecorder()
        let payload = try data(["models": []])
        let configuration = LocalAIConfiguration(provider: .lmStudio, baseURL: "http://localhost:1234", model: "")
        let client = ModelDownloadClient(configuration: configuration) { request in
            await recorder.record(request)
            return (payload, self.response(request))
        }
        let identifiers = try await client.installedModelIDs()
        XCTAssertEqual(identifiers, [])
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1234/api/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
    }

    func testNativeDiscoveryDistinguishesUnavailableServerFromEmptyLibraryWithoutFallback() async throws {
        for (status, expected): (Int, ModelDownloadError) in [
            (401, .authenticationRequired), (403, .authenticationRequired),
            (404, .endpointUnavailable), (405, .endpointUnavailable), (501, .endpointUnavailable),
            (307, .redirectBlocked), (503, .serverError(503))
        ] {
            let recorder = DownloadRecorder()
            // Even a library-shaped error body must not mark the server ready.
            let payload = try data(["models": []])
            let client = ModelDownloadClient(configuration: config()) { request in
                await recorder.record(request)
                return (payload, self.response(request, code: status))
            }
            do { _ = try await client.installedModelIDs(); XCTFail("Failed server reported an empty library") }
            catch { XCTAssertEqual(error as? ModelDownloadError, expected) }
            let paths = await recorder.requests.map { $0.url!.path }
            XCTAssertEqual(paths, ["/api/v1/models"])
        }
    }

    func testNativeDiscoveryPreservesOfflineTimeoutAndCancellationWithoutRetry() async throws {
        for code: URLError.Code in [.cannotConnectToHost, .networkConnectionLost, .timedOut, .cancelled] {
            let recorder = DownloadRecorder()
            let client = ModelDownloadClient(configuration: config()) { request in
                await recorder.record(request)
                throw URLError(code)
            }
            do { _ = try await client.installedModelIDs(); XCTFail("Failed connection reported an empty library") }
            catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ModelDownloadError, code == .timedOut ? .timedOut : .connectionFailed) }
            }
            let paths = await recorder.requests.map { $0.url!.path }
            XCTAssertEqual(paths, ["/api/v1/models"])
        }
    }

    func testInstalledLMStudioModelsIncludeUnloadedLLMsOnly() async throws {
        let recorder = DownloadRecorder()
        let payload = try data(["models": [["type": "llm", "key": "qwen/b", "quantization": ["name": "Q4_K_M"], "loaded_instances": []], ["type": "embedding", "key": "vectors"], ["type": "llm", "key": "qwen/a", "quantization": ["name": "Q4_K_M"]], ["type": "llm", "key": "qwen/b", "quantization": ["name": "Q4_K_M"]]]])
        let client = ModelDownloadClient(configuration: config()) { request in
            await recorder.record(request)
            return (payload, self.response(request))
        }
        let names = try await client.installedModelIDs()
        XCTAssertEqual(names, ["qwen/a", "qwen/b"])
        let requests = await recorder.requests
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/models")
        XCTAssertNil(requests.first?.httpBody)
        XCTAssertThrowsError(try ModelDownloadClient.parseInstalledLMStudio(data(["models": [["type": "llm"]]])))
    }

    func testNativeCatalogDiscoveryRequiresKnownQ4Quantization() throws {
        let key = "qwen2.5-1.5b-instruct"
        for record: [String: Any] in [
            ["type": "llm", "key": key, "quantization": ["name": "Q8_0"]],
            ["type": "llm", "key": key],
            ["type": "llm", "key": key, "quantization": NSNull()],
            ["type": "llm", "key": key, "quantization": ["name": NSNull()]],
            ["type": "llm", "key": key, "quantization": ["name": "Q8_0"], "variants": [key + "@q8_0"]],
            ["type": "llm", "key": key + "-q4_k_m.gguf", "quantization": ["name": "Q8_0"]]
        ] {
            XCTAssertEqual(try ModelDownloadClient.parseInstalledLMStudio(data(["models": [record]])), [])
        }
        let liveRecord: [String: Any] = ["type": "llm", "key": key, "quantization": ["name": "Q4_K_M"], "loaded_instances": []]
        XCTAssertEqual(try ModelDownloadClient.parseInstalledLMStudio(data(["models": [liveRecord]])), [key])
        for explicit in [key + "@q4_k_m", key + "-q4_k_m.gguf", key + ".Q4_K_M.gguf", "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf"] {
            XCTAssertEqual(try ModelDownloadClient.parseInstalledLMStudio(data(["models": [["type": "llm", "key": explicit]]])), [explicit])
        }
    }

    func testNativeMultipleVariantsSelectsActualQ4Identifier() throws {
        let key = "qwen2.5-1.5b-instruct"
        let q4 = key + "@q4_k_m"
        let q8 = key + "@q8_0"
        let record: [String: Any] = ["type": "llm", "key": key, "quantization": ["name": "Q8_0"], "variants": [q8, q4], "selected_variant": q8]
        let identifiers = try ModelDownloadClient.parseInstalledLMStudio(data(["models": [record]]))
        XCTAssertEqual(identifiers, [q4])
        XCTAssertEqual(ModelCatalog.recommendations[0].installedID(in: identifiers, provider: .lmStudio), q4)
        let ambiguous: [String: Any] = ["type": "llm", "key": key, "quantization": ["name": "Q4_K_M"], "variants": ["Q4_K_M"]]
        XCTAssertEqual(try ModelDownloadClient.parseInstalledLMStudio(data(["models": [ambiguous]])), [])
        let contradictory: [String: Any] = ["type": "llm", "key": key, "quantization": ["name": "Q4_K_M"], "variants": [q8]]
        XCTAssertEqual(try ModelDownloadClient.parseInstalledLMStudio(data(["models": [contradictory]])), [])
    }

    func testInstalledOllamaUsesLocalAliasFiltering() async throws {
        let payload = try data(["models": [["name": "qwen:local"], ["name": "qwen:cloud"], ["name": "hidden-alias", "remote_host": "https://ollama.com"]]])
        let client = ModelDownloadClient(configuration: config(.ollama)) { request in
            XCTAssertEqual(request.url?.path, "/api/tags")
            return (payload, self.response(request))
        }
        let names = try await client.installedModelIDs()
        XCTAssertEqual(names, ["qwen:local"])
    }

    func testDownloadSessionHasNoProxyCacheCookiesOrCredentials() {
        let configuration = ModelDownloadClient.sessionConfiguration(resourceTimeout: 100)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 100)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertTrue(configuration.connectionProxyDictionary?.isEmpty == true)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }
}

private actor DownloadRecorder {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}
private actor DownloadProgressRecorder {
    var values: [ModelDownloadProgress] = []
    func append(_ value: ModelDownloadProgress) { values.append(value) }
}
private actor DownloadPayloadQueue {
    private var payloads: [Data]
    init(_ payloads: [Data]) { self.payloads = payloads }
    func next() throws -> Data {
        guard !payloads.isEmpty else { throw ModelDownloadError.invalidResponse }
        return payloads.removeFirst()
    }
}
