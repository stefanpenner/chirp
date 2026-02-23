import Testing
import Foundation
@testable import Chirp

// MARK: - Mock URL Protocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var mockResponse: (Data, HTTPURLResponse)?
    nonisolated(unsafe) static var mockError: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request

        if let error = Self.mockError {
            client?.urlProtocol(self, didFailWithError: error)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if let (data, response) = Self.mockResponse {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func reset() {
        mockResponse = nil
        mockError = nil
        lastRequest = nil
    }
}

// MARK: - Helpers

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func httpResponse(url: String = "https://api.example.com", statusCode: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

private let testBaseURL = URL(string: "https://api.example.com")!
private let testSamples: [Float] = [0.1, 0.2, 0.3, -0.1, -0.2]
private let testSampleRate = 16000

// All provider tests are serialized because MockURLProtocol uses shared global state.
@Suite("Provider Tests", .serialized)
struct ProviderTests {

    // MARK: - OpenAI STT Tests

    @Suite("OpenAI STT Client")
    struct OpenAISTTTests {

        @Test("Happy path returns transcribed text")
        func happyPath() async throws {
            MockURLProtocol.reset()
            let json = #"{"text": "hello world"}"#
            MockURLProtocol.mockResponse = (Data(json.utf8), httpResponse(statusCode: 200))

            let client = OpenAISTTClient(baseURL: testBaseURL, apiKey: "test-key", session: mockSession())
            let result = try await client.transcribe(samples: testSamples, sampleRate: testSampleRate)

            #expect(result == "hello world")
        }

        @Test("Empty API key throws STTError.noAPIKey")
        func emptyAPIKey() async {
            MockURLProtocol.reset()

            let client = OpenAISTTClient(baseURL: testBaseURL, apiKey: "", session: mockSession())

            await #expect(throws: STTError.self) {
                _ = try await client.transcribe(samples: testSamples, sampleRate: testSampleRate)
            }
        }

        @Test("HTTP 401 throws STTError.httpError")
        func httpError() async {
            MockURLProtocol.reset()
            MockURLProtocol.mockResponse = (Data("Unauthorized".utf8), httpResponse(statusCode: 401))

            let client = OpenAISTTClient(baseURL: testBaseURL, apiKey: "test-key", session: mockSession())

            do {
                _ = try await client.transcribe(samples: testSamples, sampleRate: testSampleRate)
                Issue.record("Expected STTError.httpError but no error was thrown")
            } catch let error as STTError {
                guard case .httpError(let statusCode, _) = error else {
                    Issue.record("Expected STTError.httpError, got \(error)")
                    return
                }
                #expect(statusCode == 401)
            } catch {
                Issue.record("Expected STTError.httpError, got \(error)")
            }
        }

        @Test("Invalid JSON response throws STTError.invalidResponse")
        func invalidJSON() async {
            MockURLProtocol.reset()
            MockURLProtocol.mockResponse = (Data("not json at all".utf8), httpResponse(statusCode: 200))

            let client = OpenAISTTClient(baseURL: testBaseURL, apiKey: "test-key", session: mockSession())

            await #expect(throws: STTError.self) {
                _ = try await client.transcribe(samples: testSamples, sampleRate: testSampleRate)
            }
        }
    }

    // MARK: - OpenAI LLM Tests

    @Suite("OpenAI LLM Client")
    struct OpenAILLMTests {

        @Test("Happy path returns completion text")
        func happyPath() async throws {
            MockURLProtocol.reset()
            let json = #"{"choices":[{"message":{"content":"response"}}]}"#
            MockURLProtocol.mockResponse = (Data(json.utf8), httpResponse(statusCode: 200))

            let client = OpenAILLMClient(baseURL: testBaseURL, apiKey: "test-key", session: mockSession())
            let result = try await client.complete(system: "You are helpful", user: "Hello")

            #expect(result == "response")
        }

        @Test("Empty API key throws LLMError.noAPIKey")
        func emptyAPIKey() async {
            MockURLProtocol.reset()

            let client = OpenAILLMClient(baseURL: testBaseURL, apiKey: "", session: mockSession())

            await #expect(throws: LLMError.self) {
                _ = try await client.complete(system: "sys", user: "usr")
            }
        }

        @Test("HTTP 429 rate limit throws LLMError.httpError with status 429")
        func rateLimitError() async {
            MockURLProtocol.reset()
            MockURLProtocol.mockResponse = (Data("Rate limited".utf8), httpResponse(statusCode: 429))

            let client = OpenAILLMClient(baseURL: testBaseURL, apiKey: "test-key", session: mockSession())

            do {
                _ = try await client.complete(system: "sys", user: "usr")
                Issue.record("Expected LLMError.httpError but no error was thrown")
            } catch let error as LLMError {
                guard case .httpError(let statusCode, _) = error else {
                    Issue.record("Expected LLMError.httpError, got \(error)")
                    return
                }
                #expect(statusCode == 429)
            } catch {
                Issue.record("Expected LLMError.httpError, got \(error)")
            }
        }
    }

    // MARK: - Anthropic LLM Tests

    @Suite("Anthropic LLM Client")
    struct AnthropicLLMTests {

        @Test("Happy path returns completion text")
        func happyPath() async throws {
            MockURLProtocol.reset()
            let json = #"{"content":[{"type":"text","text":"response"}]}"#
            MockURLProtocol.mockResponse = (Data(json.utf8), httpResponse(statusCode: 200))

            let client = AnthropicLLMClient(baseURL: testBaseURL, apiKey: "test-key", session: mockSession())
            let result = try await client.complete(system: "You are helpful", user: "Hello")

            #expect(result == "response")
        }

        @Test("Request headers include x-api-key and anthropic-version")
        func verifyHeaders() async throws {
            MockURLProtocol.reset()
            let json = #"{"content":[{"type":"text","text":"ok"}]}"#
            MockURLProtocol.mockResponse = (Data(json.utf8), httpResponse(statusCode: 200))

            let client = AnthropicLLMClient(baseURL: testBaseURL, apiKey: "sk-ant-test123", session: mockSession())
            _ = try await client.complete(system: "sys", user: "usr")

            let request = MockURLProtocol.lastRequest
            #expect(request?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test123")
            #expect(request?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        }
    }

    // MARK: - Google STT Tests

    @Suite("Google STT Client")
    struct GoogleSTTTests {

        @Test("Happy path returns transcribed text")
        func happyPath() async throws {
            MockURLProtocol.reset()
            let json = #"{"results":[{"alternatives":[{"transcript":"hello"}]}]}"#
            MockURLProtocol.mockResponse = (Data(json.utf8), httpResponse(statusCode: 200))

            let client = GoogleSTTClient(baseURL: testBaseURL, apiKey: "test-key", session: mockSession())
            let result = try await client.transcribe(samples: testSamples, sampleRate: testSampleRate)

            #expect(result == "hello")
        }

        @Test("Empty results returns empty string")
        func emptyResults() async throws {
            MockURLProtocol.reset()
            let json = #"{"results":[]}"#
            MockURLProtocol.mockResponse = (Data(json.utf8), httpResponse(statusCode: 200))

            let client = GoogleSTTClient(baseURL: testBaseURL, apiKey: "test-key", session: mockSession())
            let result = try await client.transcribe(samples: testSamples, sampleRate: testSampleRate)

            #expect(result == "")
        }
    }

    // MARK: - Google LLM Tests

    @Suite("Google LLM Client")
    struct GoogleLLMTests {

        @Test("Happy path returns completion text")
        func happyPath() async throws {
            MockURLProtocol.reset()
            let json = #"{"candidates":[{"content":{"parts":[{"text":"response"}]}}]}"#
            MockURLProtocol.mockResponse = (Data(json.utf8), httpResponse(statusCode: 200))

            let client = GoogleLLMClient(baseURL: testBaseURL, apiKey: "test-key", session: mockSession())
            let result = try await client.complete(system: "You are helpful", user: "Hello")

            #expect(result == "response")
        }
    }
}
