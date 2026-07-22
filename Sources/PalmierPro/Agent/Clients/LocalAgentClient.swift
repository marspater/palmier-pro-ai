import Foundation

/// A local, auto-configuring AI client conforming to AgentClient.
/// Routes chat and reasoning requests seamlessly to Google AI Gemini, Anthropic Claude,
/// OpenAI / OpenRouter, LM Studio, or MLX Inference based on user selection.
struct LocalAgentClient: AgentClient {
    let model: AnthropicModel

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        let router = await LocalAIRouter.shared
        let selectedModel = await router.selectedChatModel

        switch selectedModel {
        case .gemini35Flash, .gemini25Flash, .veo31Fast, .veo31Lite, .geminiOmniFlash, .gemini31FlashImage, .gemini3ProImage:
            let googleKey = await router.googleAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if googleKey.isEmpty {
                continuation.yield(.textDelta("⚠️ Google AI API Key is missing. Please enter your Gemini API Key in Settings ➔ Models, or pick another model from the model selector above."))
                continuation.yield(.messageStop(stopReason: .endTurn))
                return
            }

            let modelID = selectedModel.rawValue
            await router.throttleGoogleAIRequest()
            try await streamGoogleAI(modelID: modelID, apiKey: googleKey, system: system, messages: messages, continuation: continuation)

        case .claudeSonnet, .claudeHaiku:
            let key = await router.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                continuation.yield(.textDelta("⚠️ Anthropic API Key is missing. Please enter your Anthropic API Key in Settings ➔ Models, or pick another model above."))
                continuation.yield(.messageStop(stopReason: .endTurn))
                return
            }
            let model = selectedModel == .claudeHaiku ? AnthropicModel.haiku45 : AnthropicModel.sonnet5
            let client = AnthropicClient(apiKey: key, model: model)
            for try await event in client.stream(system: system, tools: tools, messages: messages) {
                continuation.yield(event)
            }

        case .gpt4o:
            let key = await router.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                continuation.yield(.textDelta("⚠️ OpenAI / OpenRouter API Key is missing. Please enter your API Key in Settings ➔ Models, or pick another model above."))
                continuation.yield(.messageStop(stopReason: .endTurn))
                return
            }
            let urlString = key.hasPrefix("sk-or-") ? "https://openrouter.ai/api/v1/chat/completions" : "https://api.openai.com/v1/chat/completions"
            if let endpoint = URL(string: urlString) {
                let worked = try await streamOpenAICompatible(endpoint: endpoint, apiKey: key, modelName: "gpt-4o", system: system, messages: messages, continuation: continuation)
                if !worked {
                    continuation.yield(.textDelta("⚠️ Failed to connect to OpenAI / OpenRouter API endpoint."))
                    continuation.yield(.messageStop(stopReason: .endTurn))
                }
            }

        case .lmStudio:
            let lmURL = await router.lmStudioEndpoint
            if let baseURL = URL(string: lmURL),
               let completionsURL = URL(string: "chat/completions", relativeTo: baseURL.absoluteString.hasSuffix("/") ? baseURL : baseURL.appendingPathComponent("/")) {
                let worked = try await streamOpenAICompatible(endpoint: completionsURL, apiKey: nil, modelName: "local-model", system: system, messages: messages, continuation: continuation)
                if !worked {
                    continuation.yield(.textDelta("⚠️ Could not connect to LM Studio at \(lmURL). Please ensure LM Studio local server is running on port 1234."))
                    continuation.yield(.messageStop(stopReason: .endTurn))
                }
            }

        case .mlx:
            let mlxURL = await router.mlxEndpoint
            if let baseURL = URL(string: mlxURL),
               let completionsURL = URL(string: "chat/completions", relativeTo: baseURL.absoluteString.hasSuffix("/") ? baseURL : baseURL.appendingPathComponent("/")) {
                let worked = try await streamOpenAICompatible(endpoint: completionsURL, apiKey: nil, modelName: "mlx-model", system: system, messages: messages, continuation: continuation)
                if !worked {
                    continuation.yield(.textDelta("⚠️ Could not connect to MLX Inference server at \(mlxURL). Please ensure MLX server is running on port 8080."))
                    continuation.yield(.messageStop(stopReason: .endTurn))
                }
            }
        }
    }

    private func streamOpenAICompatible(
        endpoint: URL,
        apiKey: String?,
        modelName: String,
        system: String,
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws -> Bool {
        var openAIMessages: [[String: Any]] = [["role": "system", "content": system]]
        for msg in messages {
            let text = msg.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            openAIMessages.append(["role": msg.role.rawValue, "content": text])
        }

        let body: [String: Any] = [
            "model": modelName,
            "messages": openAIMessages,
            "stream": true,
            "temperature": 0.7
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty else { continue }

            continuation.yield(.textDelta(content))
        }

        continuation.yield(.messageStop(stopReason: .endTurn))
        return true
    }

    private func streamGoogleAI(
        modelID: String,
        apiKey: String,
        system: String,
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        let sanitizedModel = ChatAIModel.sanitize(modelString: modelID)

        // Exact Google AI Studio REST v1beta streaming endpoint (without alt=sse query param which triggers 404)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(sanitizedModel):streamGenerateContent?key=\(apiKey)") else {
            throw PalmierClientError.upstream("Invalid Google AI endpoint URL for model \(sanitizedModel)")
        }

        var contents: [[String: Any]] = []
        for msg in messages {
            let role = msg.role == .user ? "user" : "model"
            let text = msg.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            contents.append([
                "role": role,
                "parts": [["text": text]]
            ])
        }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }

            // Extract Google AI Studio JSON error details if present
            var apiErrorMessage = errorBody
            var apiErrorStatus = "\(http.statusCode)"
            if let data = errorBody.data(using: .utf8),
               let jsonObj = try? JSONSerialization.jsonObject(with: data) {
                let errDict: [String: Any]? = {
                    if let dict = jsonObj as? [String: Any] {
                        return dict["error"] as? [String: Any]
                    } else if let arr = jsonObj as? [[String: Any]], let first = arr.first {
                        return first["error"] as? [String: Any]
                    }
                    return nil
                }()
                if let errDict {
                    if let msg = errDict["message"] as? String { apiErrorMessage = msg }
                    if let status = errDict["status"] as? String { apiErrorStatus = status }
                }
            }

            if http.statusCode == 429 {
                let notice = """
                ⚠️ Google AI Studio Error (HTTP 429 - \(apiErrorStatus)):
                \(apiErrorMessage)

                The Google AI Studio Free Tier enforces a 5 Requests Per Minute (5 RPM) limit.

                Suggestions:
                • Wait ~60 seconds for the quota window to reset.
                • Or switch to another model (Claude, OpenRouter, LM Studio, MLX) in the header selector.
                """
                continuation.yield(.textDelta(notice))
                continuation.yield(.messageStop(stopReason: .endTurn))
                return
            }

            let notice = """
            ⚠️ Google AI Studio Error (HTTP \(http.statusCode) - \(apiErrorStatus)):
            \(apiErrorMessage)
            """
            continuation.yield(.textDelta(notice))
            continuation.yield(.messageStop(stopReason: .endTurn))
            return
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }

            for part in parts {
                if let text = part["text"] as? String {
                    continuation.yield(.textDelta(text))
                }
            }
        }

        continuation.yield(.messageStop(stopReason: .endTurn))
    }
}
