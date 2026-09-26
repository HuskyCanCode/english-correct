import XCTest
@testable import EnglishCorrectCore

final class ModelCatalogTests: XCTestCase {
    private let fast = ModelCatalog.recommendations[0]
    private let pro = ModelCatalog.recommendations[1]

    func testCatalogHasDistinctTiersAndProviderSpecificDownloadEstimates() {
        XCTAssertEqual(ModelCatalog.recommendations.map(\.id), ["fast", "pro"])
        XCTAssertEqual(ModelCatalog.recommendations.map(\.tier), ["Fast", "Pro"])
        XCTAssertEqual(fast.downloadBytes(for: .lmStudio), 1_117_320_736)
        XCTAssertEqual(fast.downloadBytes(for: .ollama), 986_000_000)
        XCTAssertEqual(pro.downloadBytes(for: .lmStudio), 3_993_201_344 + 689_872_288)
        XCTAssertEqual(pro.downloadBytes(for: .ollama), 4_700_000_000)
        XCTAssertEqual(fast.recommendedMemoryGB, 8)
        XCTAssertEqual(pro.recommendedMemoryGB, 16)
    }

    func testSourcesAndLicensesPointToTheOfficialExactModels() {
        XCTAssertEqual(fast.sourceURL.absoluteString, "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF")
        XCTAssertEqual(pro.sourceURL.absoluteString, "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF")
        for recommendation in ModelCatalog.recommendations {
            XCTAssertEqual(recommendation.licenseURL.absoluteString, recommendation.sourceURL.absoluteString + "/blob/main/LICENSE")
            XCTAssertEqual(recommendation.downloadSpec.catalogID, recommendation.id)
            XCTAssertEqual(recommendation.downloadSpec.lmStudioRepository, recommendation.sourceURL.absoluteString)
            XCTAssertEqual(recommendation.downloadSpec.quantization, "Q4_K_M")
        }
        XCTAssertEqual(fast.downloadSpec.ollamaModel, "qwen2.5:1.5b-instruct-q4_K_M")
        XCTAssertEqual(pro.downloadSpec.ollamaModel, "qwen2.5:7b-instruct-q4_K_M")
    }

    func testLMStudioRecognizesExactCatalogKeysAndGGUFFilenames() {
        for identifier in [
            "qwen2.5-1.5b-instruct",
            "qwen/qwen2.5-1.5b-instruct",
            "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
            "qwen2.5-1.5b-instruct-q4_k_m",
            "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
            "Qwen2.5-1.5B-Instruct.Q4_K_M.gguf",
            "qwen2.5-1.5b-instruct@q4_k_m",
            "qwen/qwen2.5-1.5b-instruct-gguf@q4_k_m",
            "Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            "lmstudio-community/Qwen2.5-1.5B-Instruct-GGUF/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
        ] {
            XCTAssertEqual(fast.installedID(in: [identifier], provider: .lmStudio), identifier)
            XCTAssertNil(pro.installedID(in: [identifier], provider: .lmStudio))
        }
        let shard = "Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf"
        XCTAssertEqual(pro.installedID(in: [shard], provider: .lmStudio), shard)
        XCTAssertNil(fast.installedID(in: [shard], provider: .lmStudio))
    }

    func testLMStudioRejectsWrongModelQuantizationAdaptersAndSubstringConfusion() {
        for identifier in [
            "qwen2.5-15b-instruct", "qwen2.5-7b-instruct", "qwen2.5-1.5b",
            "qwen2.5-1.5b-base", "qwen2.5-coder-1.5b-instruct",
            "qwen2.5-1.5b-instruct-coder", "qwen2.5-1.5b-instruct-adapter",
            "qwen2.5-1.5b-instruct-q8_0.gguf", "qwen2.5-1.5b-instruct@q8_0",
            "qwen2.5-1.5b-instruct-gguf@q8_0", "my-qwen2.5-1.5b-instruct",
            "qwen2.5-1.5b-instruct-abliterated", "qwen2.5-1.5b-instruct-merged",
            "custom-adapter/qwen2.5-1.5b-instruct",
            "Qwen/Qwen2.5-1.5B-Instruct-Adapter/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            "Qwen/Qwen2.5-7B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf",
            "/qwen2.5-1.5b-instruct", "qwen//qwen2.5-1.5b-instruct",
            "qwen2.5-1.5b-instruct ", " qwen2.5-1.5b-instruct", ""
        ] {
            XCTAssertNil(fast.installedID(in: [identifier], provider: .lmStudio), identifier)
        }
        XCTAssertNil(pro.installedID(in: ["qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf"], provider: .lmStudio))
    }

    func testOllamaAcceptsOnlyExplicitRecommendedTagOrItsDefaultSizeAlias() {
        for (recommendation, size) in [(fast, "1.5b"), (pro, "7b")] {
            let explicit = "qwen2.5:\(size)-instruct-q4_K_M"
            let alias = "qwen2.5:\(size)"
            XCTAssertEqual(recommendation.installedID(in: [explicit], provider: .ollama), explicit)
            XCTAssertEqual(recommendation.installedID(in: [alias], provider: .ollama), alias)
            XCTAssertEqual(recommendation.installedID(in: [alias, explicit], provider: .ollama), explicit)
            for wrong in [
                "qwen2.5", "qwen2.5:latest", "qwen2.5:\(size)-base",
                "qwen2.5:\(size)-instruct-q8_0", "qwen2.5:\(size)-instruct",
                "qwen2.5-coder:\(size)", "qwen2.5:\(size)-cloud",
                "custom/qwen2.5:\(size)", "qwen2.5:\(size)-instruct-q4_K_M-adapter"
            ] {
                XCTAssertNil(recommendation.installedID(in: [wrong], provider: .ollama), wrong)
            }
        }
        XCTAssertNil(fast.installedID(in: ["qwen2.5:7b"], provider: .ollama))
        XCTAssertNil(pro.installedID(in: ["qwen2.5:1.5b"], provider: .ollama))
    }

    func testMatchingPreservesServerIdentifierAndSkipsMisleadingFirstEntry() {
        let actual = "Qwen/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
        XCTAssertEqual(fast.installedID(in: ["qwen2.5-coder-1.5b-instruct", actual], provider: .lmStudio), actual)
        XCTAssertNil(fast.installedID(in: [], provider: .lmStudio))
        XCTAssertNil(pro.installedID(in: [], provider: .ollama))
    }
}
