// ONNXSession.swift — Thin Swift wrapper around the ORT C API.
// Manages OrtEnv, OrtSession, and OrtSessionOptions lifecycle.
// Provides a `run()` method that takes named input tensors and returns output tensors.

import Foundation
import COnnxRuntime

// MARK: - Tensor

/// A named tensor for ORT input/output.
struct ONNXTensor: @unchecked Sendable {
    let name: String
    let data: Data        // raw bytes (e.g. Int64 or Float32)
    let shape: [Int64]
    let elementType: ONNXElementType
}

enum ONNXElementType {
    case float32
    case int64

    var ortType: ONNXTensorElementDataType {
        switch self {
        case .float32: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
        case .int64:   return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
        }
    }
}

// MARK: - Session

/// Swift wrapper around an ORT inference session.
/// Thread-safe: ORT sessions support concurrent Run() calls.
final class ONNXSession: @unchecked Sendable {
    private let api: UnsafePointer<OrtApi>
    private let env: OpaquePointer        // OrtEnv*
    private let session: OpaquePointer    // OrtSession*

    enum ORTError: Error, LocalizedError {
        case apiNotAvailable
        case createEnvFailed(String)
        case createSessionFailed(String)
        case runFailed(String)
        case outputError(String)

        var errorDescription: String? {
            switch self {
            case .apiNotAvailable: return "ORT API not available"
            case .createEnvFailed(let msg): return "ORT CreateEnv failed: \(msg)"
            case .createSessionFailed(let msg): return "ORT CreateSession failed: \(msg)"
            case .runFailed(let msg): return "ORT Run failed: \(msg)"
            case .outputError(let msg): return "ORT output error: \(msg)"
            }
        }
    }

    /// Initialize a session from an ONNX model file path.
    init(modelPath: String) throws {
        guard let apiBase = OrtGetApiBase() else {
            throw ORTError.apiNotAvailable
        }
        guard let apiPtr = apiBase.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw ORTError.apiNotAvailable
        }
        self.api = apiPtr

        // Create environment
        var envPtr: OpaquePointer?
        let envStatus = api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "chirp", &envPtr)
        if let envStatus {
            let msg = Self.extractMessage(api: apiPtr, status: envStatus)
            api.pointee.ReleaseStatus(envStatus)
            throw ORTError.createEnvFailed(msg)
        }
        guard let envPtr else { throw ORTError.createEnvFailed("null env") }
        self.env = envPtr

        // Create session options
        var optsPtr: OpaquePointer?
        let optsStatus = api.pointee.CreateSessionOptions(&optsPtr)
        if let optsStatus {
            let msg = Self.extractMessage(api: apiPtr, status: optsStatus)
            api.pointee.ReleaseStatus(optsStatus)
            api.pointee.ReleaseEnv(envPtr)
            throw ORTError.createSessionFailed(msg)
        }

        // Create session
        var sessionPtr: OpaquePointer?
        let sessionStatus = api.pointee.CreateSession(envPtr, modelPath, optsPtr, &sessionPtr)
        if let optsPtr { api.pointee.ReleaseSessionOptions(optsPtr) }
        if let sessionStatus {
            let msg = Self.extractMessage(api: apiPtr, status: sessionStatus)
            api.pointee.ReleaseStatus(sessionStatus)
            api.pointee.ReleaseEnv(envPtr)
            throw ORTError.createSessionFailed(msg)
        }
        guard let sessionPtr else {
            api.pointee.ReleaseEnv(envPtr)
            throw ORTError.createSessionFailed("null session")
        }
        self.session = sessionPtr
    }

    deinit {
        api.pointee.ReleaseSession(session)
        api.pointee.ReleaseEnv(env)
    }

    /// Run inference with named inputs. Returns outputs for the requested output names.
    func run(inputs: [ONNXTensor], outputNames: [String]) throws -> [ONNXTensor] {
        // Create input OrtValues
        // Pin input data as NSData so pointers remain valid for the entire Run() call.
        // CreateTensorWithDataAsOrtValue wraps the pointer without copying,
        // so the underlying memory must stay alive until Run() completes.
        var pinnedData: [NSData] = []
        var inputValues: [OpaquePointer?] = []
        var inputNamePtrs: [UnsafePointer<CChar>?] = []
        var inputNameStrings: [String] = []
        defer {
            for val in inputValues { if let val { api.pointee.ReleaseValue(val) } }
        }

        for input in inputs {
            let nsData = input.data as NSData
            pinnedData.append(nsData)
            let value = try createTensorValue(nsData: nsData, shape: input.shape, elementType: input.elementType)
            inputValues.append(value)
            inputNameStrings.append(input.name)
        }

        // Prepare name C strings (keep alive for the duration of Run)
        let inputCStrings = inputNameStrings.map { $0.withCString { strdup($0) } }
        defer { inputCStrings.forEach { free($0) } }
        inputNamePtrs = inputCStrings.map { UnsafePointer($0) }

        let outputCStrings = outputNames.map { $0.withCString { strdup($0) } }
        defer { outputCStrings.forEach { free($0) } }
        var outputNamePtrs = outputCStrings.map { UnsafePointer($0) }

        // Create run options
        var runOpts: OpaquePointer?
        let roStatus = api.pointee.CreateRunOptions(&runOpts)
        if let roStatus {
            let msg = Self.extractMessage(api: api, status: roStatus)
            api.pointee.ReleaseStatus(roStatus)
            throw ORTError.runFailed(msg)
        }
        defer { if let runOpts { api.pointee.ReleaseRunOptions(runOpts) } }

        // Allocate output value pointers
        var outputValues = [OpaquePointer?](repeating: nil, count: outputNames.count)
        defer {
            for val in outputValues { if let val { api.pointee.ReleaseValue(val) } }
        }

        // Run
        let runStatus = api.pointee.Run(
            session,
            runOpts,
            inputNamePtrs,
            inputValues,
            inputValues.count,
            &outputNamePtrs,
            outputNames.count,
            &outputValues
        )
        if let runStatus {
            let msg = Self.extractMessage(api: api, status: runStatus)
            api.pointee.ReleaseStatus(runStatus)
            throw ORTError.runFailed(msg)
        }

        // Extract output tensors
        var results: [ONNXTensor] = []
        for (i, name) in outputNames.enumerated() {
            guard let outVal = outputValues[i] else {
                throw ORTError.outputError("null output for \(name)")
            }
            let tensor = try extractTensor(value: outVal, name: name)
            results.append(tensor)
        }
        return results
    }

    // MARK: - Private helpers

    private func createTensorValue(nsData: NSData, shape: [Int64], elementType: ONNXElementType) throws -> OpaquePointer {
        // Create memory info for CPU
        var memInfo: OpaquePointer?
        let miStatus = api.pointee.CreateCpuMemoryInfo(
            OrtArenaAllocator, OrtMemTypeDefault, &memInfo
        )
        if let miStatus {
            let msg = Self.extractMessage(api: api, status: miStatus)
            api.pointee.ReleaseStatus(miStatus)
            throw ORTError.runFailed(msg)
        }
        defer { if let memInfo { api.pointee.ReleaseMemoryInfo(memInfo) } }

        var shape = shape
        var value: OpaquePointer?

        // NSData.bytes returns a pointer stable for the object's lifetime.
        // The caller keeps the NSData alive (via pinnedData array) for the
        // duration of the ORT Run() call.
        let mutPtr = UnsafeMutableRawPointer(mutating: nsData.bytes)
        let createStatus = api.pointee.CreateTensorWithDataAsOrtValue(
            memInfo,
            mutPtr,
            nsData.length,
            &shape,
            shape.count,
            elementType.ortType,
            &value
        )

        if let createStatus {
            let msg = Self.extractMessage(api: api, status: createStatus)
            api.pointee.ReleaseStatus(createStatus)
            throw ORTError.runFailed(msg)
        }
        guard let value else { throw ORTError.runFailed("null tensor value") }
        return value
    }

    private func extractTensor(value: OpaquePointer, name: String) throws -> ONNXTensor {
        // Get tensor type and shape info
        var typeInfo: OpaquePointer?
        let tiStatus = api.pointee.GetTensorTypeAndShape(value, &typeInfo)
        if let tiStatus {
            let msg = Self.extractMessage(api: api, status: tiStatus)
            api.pointee.ReleaseStatus(tiStatus)
            throw ORTError.outputError(msg)
        }
        defer { if let typeInfo { api.pointee.ReleaseTensorTypeAndShapeInfo(typeInfo) } }

        // Get element type
        var elementType: ONNXTensorElementDataType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
        let etStatus = api.pointee.GetTensorElementType(typeInfo, &elementType)
        if let etStatus {
            let msg = Self.extractMessage(api: api, status: etStatus)
            api.pointee.ReleaseStatus(etStatus)
            throw ORTError.outputError(msg)
        }

        // Get shape
        var dimCount: Int = 0
        let dcStatus = api.pointee.GetDimensionsCount(typeInfo, &dimCount)
        if let dcStatus {
            let msg = Self.extractMessage(api: api, status: dcStatus)
            api.pointee.ReleaseStatus(dcStatus)
            throw ORTError.outputError(msg)
        }

        var dims = [Int64](repeating: 0, count: dimCount)
        let gdStatus = api.pointee.GetDimensions(typeInfo, &dims, dimCount)
        if let gdStatus {
            let msg = Self.extractMessage(api: api, status: gdStatus)
            api.pointee.ReleaseStatus(gdStatus)
            throw ORTError.outputError(msg)
        }

        // Get data pointer
        var rawPtr: UnsafeMutableRawPointer?
        let dataStatus = api.pointee.GetTensorMutableData(value, &rawPtr)
        if let dataStatus {
            let msg = Self.extractMessage(api: api, status: dataStatus)
            api.pointee.ReleaseStatus(dataStatus)
            throw ORTError.outputError(msg)
        }
        guard let rawPtr else { throw ORTError.outputError("null tensor data") }

        // Calculate byte count
        let elementCount = dims.reduce(1, { $0 * Int($1) })
        let swiftElementType: ONNXElementType
        let bytesPerElement: Int
        switch elementType {
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
            swiftElementType = .float32
            bytesPerElement = 4
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:
            swiftElementType = .int64
            bytesPerElement = 8
        default:
            throw ORTError.outputError("unsupported element type \(elementType.rawValue)")
        }

        let byteCount = elementCount * bytesPerElement
        let data = Data(bytes: rawPtr, count: byteCount)

        return ONNXTensor(name: name, data: data, shape: dims, elementType: swiftElementType)
    }

    private static func extractMessage(api: UnsafePointer<OrtApi>, status: OpaquePointer) -> String {
        if let msgPtr = api.pointee.GetErrorMessage(status) {
            return String(cString: msgPtr)
        }
        return "unknown error"
    }
}
