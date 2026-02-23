// HTTPHelper.swift — Shared HTTP request/response helpers for cloud providers.
// Reduces duplicated boilerplate across OpenAI, Anthropic, and Google providers.

import Foundation

/// Lightweight helpers for HTTP request execution and JSON response parsing.
/// Each provider still owns its own request construction (URL, headers, body).
enum HTTPHelper {

    // MARK: - Execute & Validate

    /// Executes a URLRequest, validates the HTTP status code, and returns the response data.
    /// On non-200 status, calls `makeHTTPError` to produce the appropriate domain error.
    static func performRequest(
        _ request: URLRequest,
        session: URLSession = .shared,
        makeHTTPError: (Int, String) -> any Error
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw makeHTTPError(0, "Not an HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw makeHTTPError(httpResponse.statusCode, errorBody)
        }
        return data
    }

    // MARK: - JSON Parsing

    /// Parses response data as a JSON dictionary (`[String: Any]`).
    /// Throws `makeInvalidResponseError()` if parsing fails or the top-level value isn't a dictionary.
    static func parseJSON(
        _ data: Data,
        makeInvalidResponseError: () -> any Error
    ) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw makeInvalidResponseError()
        }
        return json
    }
}
