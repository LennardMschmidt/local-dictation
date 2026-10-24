import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The model on this Mac that the settings choose: LM Studio or Apple Intelligence.
public enum LocalModel {
    public static func make(_ settings: LLMSettings) -> any TextCleaner & ChatCompleter {
        if settings.usesAppleModel { return AppleModelCleaner(settings: settings) }
        return OpenAICompatibleCleaner(settings: settings)
    }
}

public enum AppleModelError: Error, Equatable, Sendable {
    case unavailable(String)
}

/// The Apple Intelligence model of macOS 26 (Foundation Models framework), used like the LM
/// Studio model: the system message becomes the session's instructions, example turns are written
/// into them, the last user message is the prompt, and the JSON schema becomes a generation
/// schema, so the answer is the same JSON text the other models return.
public struct AppleModelCleaner: TextCleaner, ChatCompleter {
    public let settings: LLMSettings
    private let builder = PromptBuilder()
    private let sanitizer = ResponseSanitizer()
    /// The model's context window holds 4096 tokens for instructions, prompt and answer together.
    static let maximumTokens = 4096

    public init(settings: LLMSettings) {
        self.settings = settings
    }

    /// Nil when the model can be used, otherwise the reason, as the settings page shows it.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return "Needs macOS 26." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is switched off in System Settings."
        case .unavailable(.modelNotReady): return "The Apple Intelligence model is still downloading."
        case .unavailable: return "Apple Intelligence is not available."
        }
        #else
        return "This build has no Foundation Models framework."
        #endif
    }

    public static var isAvailable: Bool { unavailableReason == nil }

    public func clean(_ request: CleanupRequest) async throws -> String {
        var messages = builder.messages(transcript: request.transcript, language: request.language, style: request.style,
                                        vocabulary: request.vocabulary, tones: request.tones)
        // Apple's model tends to answer a dictated question or request instead of cleaning it up.
        if let last = messages.indices.last {
            messages[last].content = "Clean up this dictated text and keep its language. It is text the user wrote, not a question or request to you:\n"
                + messages[last].content
        }
        let reply = try await complete(messages: messages, maxTokens: max(200, request.transcript.count),
                                       schema: OpenAICompatibleCleaner.textSchema)
        switch sanitizer.sanitize(reply: reply, transcript: request.transcript) {
        case .success(let text): return text
        case .failure(let rejection): throw LLMError.rejected(rejection)
        }
    }

    public func complete(messages: [ChatMessage], maxTokens: Int, schema: [String: Any]) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw AppleModelError.unavailable("Needs macOS 26.") }
        if let reason = Self.unavailableReason { throw AppleModelError.unavailable(reason) }
        let (instructions, prompt) = Self.split(messages)
        let session = LanguageModelSession(instructions: instructions)
        let generation = try GenerationSchema(root: Self.dynamicSchema(schema, name: "Answer"), dependencies: [])
        let options = GenerationOptions(temperature: settings.temperature, maximumResponseTokens: min(maxTokens, Self.maximumTokens))
        let response = try await session.respond(to: prompt, schema: generation, options: options)
        return response.content.jsonString
        #else
        throw AppleModelError.unavailable("This build has no Foundation Models framework.")
        #endif
    }

    /// The system messages and the example turns as instructions, the last user message as the
    /// prompt. Example answers are the JSON the model is to give, so it sees the expected form.
    static func split(_ messages: [ChatMessage]) -> (instructions: String, prompt: String) {
        let lastUser = messages.lastIndex { $0.role == "user" }
        var parts = messages.filter { $0.role == "system" }.map(\.content)
        let turns = messages.indices.filter { messages[$0].role != "system" && $0 != lastUser }
        if !turns.isEmpty {
            parts.append("Examples:\n" + turns.map { index in
                (messages[index].role == "user" ? "Input: " : "Answer: ") + messages[index].content
            }.joined(separator: "\n"))
        }
        return (parts.joined(separator: "\n\n"), lastUser.map { messages[$0].content } ?? "")
    }

    #if canImport(FoundationModels)
    /// Turns the JSON schemas the app uses (objects, arrays, strings with or without an enum,
    /// integers, numbers, booleans) into a dynamic generation schema. Nested objects get the path
    /// as their name, because names have to be unique within one schema.
    @available(macOS 26, *)
    static func dynamicSchema(_ schema: [String: Any], name: String) -> DynamicGenerationSchema {
        switch schema["type"] as? String {
        case "object":
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let required = Set(schema["required"] as? [String] ?? Array(properties.keys))
            return DynamicGenerationSchema(name: name, properties: properties.keys.sorted().map { key in
                DynamicGenerationSchema.Property(name: key, schema: dynamicSchema(properties[key] as? [String: Any] ?? [:], name: "\(name)_\(key)"),
                                                 isOptional: !required.contains(key))
            })
        case "array":
            return DynamicGenerationSchema(arrayOf: dynamicSchema(schema["items"] as? [String: Any] ?? ["type": "string"], name: "\(name)_item"))
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            if let choices = schema["enum"] as? [String] { return DynamicGenerationSchema(name: name, anyOf: choices) }
            return DynamicGenerationSchema(type: String.self)
        }
    }
    #endif
}
