// RetryHelper.swift — Simple retry with exponential backoff for cloud API calls.

import Foundation

enum RetryHelper {
    /// Retry an async throwing operation with exponential backoff.
    /// Only retries on transient errors (network errors, HTTP 429/5xx).
    static func withRetry<T>(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard isRetryable(error), attempt < maxAttempts - 1 else {
                    throw error
                }
                let delay = baseDelay * pow(2.0, Double(attempt))
                let jitter = Double.random(in: 0...0.5)
                try await Task.sleep(nanoseconds: UInt64((delay + jitter) * 1_000_000_000))
            }
        }
        throw lastError!
    }

    private static func isRetryable(_ error: Error) -> Bool {
        // Network-level errors (URLError)
        if error is URLError { return true }

        // HTTP 429 (rate limit) or 5xx (server error)
        if let sttError = error as? STTError,
           case .httpError(let code, _) = sttError {
            return code == 429 || (500...599).contains(code)
        }
        if let llmError = error as? LLMError,
           case .httpError(let code, _) = llmError {
            return code == 429 || (500...599).contains(code)
        }

        return false
    }
}
