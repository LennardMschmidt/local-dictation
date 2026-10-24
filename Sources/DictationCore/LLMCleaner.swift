import Foundation

/// Input for one cleanup request.
public struct CleanupRequest: Sendable {
    public var transcript: String
    public var language: String
    public var style: AppStyle
    public var vocabulary: [String]
    public var tones: [AppStyle: Tone]

    public init(transcript: String, language: String, style: AppStyle, vocabulary: [String],
                tones: [AppStyle: Tone] = [:]) {
        self.transcript = transcript
        self.language = language
        self.style = style
        self.vocabulary = vocabulary
        self.tones = tones
    }
}

public protocol TextCleaner: Sendable {
    /// Returns the cleaned text or throws. The pipeline falls back to the raw transcript on errors.
    func clean(_ request: CleanupRequest) async throws -> String
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        return (data, http)
    }
}

public enum LLMError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int, String)
    case missingContent
    case rejected(ResponseSanitizer.Rejection)
}

/// Cleans text through an OpenAI-compatible `/v1/chat/completions` endpoint such as LM Studio.
public struct OpenAICompatibleCleaner: TextCleaner, ChatCompleter {
    public let settings: LLMSettings
    private let transport: HTTPTransport
    private let builder = PromptBuilder()
    private let sanitizer = ResponseSanitizer()

    /// Upper bound for one request. The pipeline cancels earlier with a timeout that grows with
    /// the transcript length, see `DictationPipeline`.
    static let requestTimeout: TimeInterval = 120

    public init(settings: LLMSettings, transport: HTTPTransport? = nil) {
        self.settings = settings
        self.transport = transport ?? URLSessionTransport(timeout: Self.requestTimeout)
    }

    public func clean(_ request: CleanupRequest) async throws -> String {
        let reply = try await complete(messages: messages(for: request), maxTokens: max(200, request.transcript.count))
        switch sanitizer.sanitize(reply: reply, transcript: request.transcript) {
        case .success(let text): return text
        case .failure(let rejection): throw LLMError.rejected(rejection)
        }
    }

    /// The default answer shape: `{"text": "..."}`.
    public static let textSchema: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string"]],
        "required": ["text"],
        "additionalProperties": false,
    ]

    /// Sends a chat completion whose answer must follow `schema` and returns the raw reply.
    public func complete(messages: [ChatMessage], maxTokens: Int,
                         schema: [String: Any] = OpenAICompatibleCleaner.textSchema) async throws -> String {
        let urlRequest = try makeURLRequest(messages: messages, maxTokens: maxTokens, schema: schema)
        let (data, response) = try await transport.send(urlRequest)
        guard (200..<300).contains(response.statusCode) else {
            throw LLMError.httpStatus(response.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let reply = Self.content(from: data) else { throw LLMError.missingContent }
        return reply
    }

    func messages(for request: CleanupRequest) -> [ChatMessage] {
        builder.messages(
            transcript: request.transcript,
            language: request.language,
            style: request.style,
            vocabulary: request.vocabulary,
            tones: request.tones
        )
    }

    func makeURLRequest(for request: CleanupRequest) throws -> URLRequest {
        try makeURLRequest(messages: messages(for: request), maxTokens: max(200, request.transcript.count))
    }

    func makeURLRequest(messages: [ChatMessage], maxTokens: Int,
                        schema: [String: Any] = OpenAICompatibleCleaner.textSchema) throws -> URLRequest {
        let base = settings.baseURL.hasSuffix("/") ? String(settings.baseURL.dropLast()) : settings.baseURL
        guard let url = URL(string: base + "/v1/chat/completions") else { throw LLMError.invalidResponse }
        let body: [String: Any] = [
            "model": settings.model,
            "temperature": settings.temperature,
            "max_tokens": maxTokens,
            "stream": false,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "answer", "strict": true, "schema": schema],
            ],
        ]
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = Self.requestTimeout
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func content(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return content
    }
}
