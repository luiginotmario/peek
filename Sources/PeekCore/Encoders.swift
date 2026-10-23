import CoreGraphics
import CoreML
import Foundation
import Tokenizers
import Vision

/// The files `scripts/convert-model.py` writes: two compiled Core ML models, the tokenizer and siglip.json.
public struct ModelFiles: Sendable {
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    var imageEncoder: URL { folder.appending(path: "ImageEncoder.mlmodelc") }
    var textEncoder: URL { folder.appending(path: "TextEncoder.mlmodelc") }
    var tokenizer: URL { folder.appending(path: "tokenizer") }
    var meta: URL { folder.appending(path: "siglip.json") }
}

/// The numbers the conversion script reads off the pytorch model.
public struct SiglipMeta: Codable, Sendable {
    public var imageSize: Int
    public var textLength: Int
    public var dimensions: Int
    public var logitScale: Float
    public var logitBias: Float
    public var padId: Int

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(SiglipMeta.self, from: Data(contentsOf: url))
    }

    /// SigLIP is trained with a sigmoid, so a cosine maps to an honest match probability.
    public func probability(_ cosine: Float) -> Float {
        1 / (1 + exp(-(cosine * logitScale + logitBias)))
    }
}

public enum EncoderError: Error {
    case missingInput(String)
    case missingOutput
}

private func configuration() -> MLModelConfiguration {
    let configuration = MLModelConfiguration()
    // the neural engine is the low-power path, and the gpu compiler rejects the text encoder
    configuration.computeUnits = .cpuAndNeuralEngine
    return configuration
}

private func embedding(from features: any MLFeatureProvider) throws -> [Float] {
    guard let array = features.featureValue(for: "embedding")?.multiArrayValue else { throw EncoderError.missingOutput }
    return (0..<array.count).map { array[$0].floatValue }
}

/// Turns a photo into a 768-d unit vector. Loaded only while indexing.
public final class ImageEncoder {
    private let model: MLModel
    private let constraint: MLImageConstraint

    public init(files: ModelFiles) throws {
        model = try MLModel(contentsOf: files.imageEncoder, configuration: configuration())
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw EncoderError.missingInput("image")
        }
        self.constraint = constraint
    }

    /// Encodes a batch in one call so core ml can keep the neural engine busy.
    public func encode(_ images: [CGImage]) throws -> [[Float]] {
        // siglip squashes the whole frame to a square rather than cropping it
        let options: [MLFeatureValue.ImageOption: Any] = [
            .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue,
        ]
        let inputs = try images.map { image in
            let value = try MLFeatureValue(cgImage: image, constraint: constraint, options: options)
            return try MLDictionaryFeatureProvider(dictionary: ["image": value])
        }
        let outputs = try model.predictions(from: MLArrayBatchProvider(array: inputs), options: MLPredictionOptions())
        return try (0..<outputs.count).map { try embedding(from: outputs.features(at: $0)) }
    }
}

/// Turns a query into a vector in the same space as the photos. Loaded only while searching.
public final class TextEncoder {
    private let model: MLModel
    private let tokenizer: any Tokenizer
    private let meta: SiglipMeta

    public init(files: ModelFiles) async throws {
        model = try MLModel(contentsOf: files.textEncoder, configuration: configuration())
        tokenizer = try await AutoTokenizer.from(modelFolder: files.tokenizer)
        meta = try SiglipMeta(contentsOf: files.meta)
    }

    /// Token ids exactly as the pytorch processor makes them: lowercased, eos-terminated, padded to 64.
    public func tokens(for text: String) -> [Int] {
        var ids = Array(tokenizer.encode(text: text.lowercased(), addSpecialTokens: true).prefix(meta.textLength))
        ids += Array(repeating: meta.padId, count: meta.textLength - ids.count)
        return ids
    }

    public func encode(_ text: String) throws -> [Float] {
        let ids = tokens(for: text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: meta.textLength)], dataType: .int32)
        for (index, id) in ids.enumerated() {
            array[index] = NSNumber(value: Int32(id))
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["ids": MLFeatureValue(multiArray: array)])
        return try embedding(from: model.prediction(from: input))
    }
}
