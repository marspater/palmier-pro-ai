import Foundation

/// A local, auto-configuring AI client conforming to AgentClient.
/// Routes chat and reasoning requests seamlessly to local LLMs (LM Studio on port 1234, MLX on port 8080),
/// Google AI Pro (Gemini 2.0), or returns clear status guidance without remote login requirements.
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
        let googleKey = await router.googleAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let lmStudioURL = await router.lmStudioEndpoint
        let mlxURL = await router.mlxEndpoint

        // 1. If Google AI Gemini API Key is provided in Settings -> Models, route to Gemini API
        if !googleKey.isEmpty {
            try await streamGoogleAI(
                apiKey: googleKey,
                system: system,
                messages: messages,
                continuation: continuation
            )
            return
        }

        // 2. Check local OpenAI-compatible endpoints (LM Studio or MLX Inference)
        let candidateEndpoints = [lmStudioURL, mlxURL, "http://localhost:1234/v1", "http://localhost:8080/v1"]
        for endpointString in candidateEndpoints {
            if let baseURL = URL(string: endpointString),
               let completionsURL = URL(string: "chat/completions", relativeTo: baseURL.absoluteString.hasSuffix("/") ? baseURL : baseURL.appendingPathComponent("/")) {
                if let streamWorked = try? await streamOpenAICompatible(
                    endpoint: completionsURL,
                    system: system,
                    messages: messages,
                    continuation: continuation
                ), streamWorked {
                    return
                }
            }
        }

        // 3. Fallback: Friendly auto-configuration guide for local hardware & AI backends
        let helpNotice = """
        Connected to Palmier Pro Local AI Hardware Router.

        To stream agent reasoning:
        • Option A: Start LM Studio on port 1234 (http://localhost:1234/v1) or MLX on port 8080.
        • Option B: Enter your Google AI Pro (Gemini) API Key or Anthropic API Key in Settings ➔ Models.

        Your local Metal hardware handles all video/image upscaling automatically.
        """
        continuation.yield(.textDelta(helpNotice))
        continuation.yield(.messageStop(stopReason: .endTurn))
    }

    private func streamOpenAICompatible(
        endpoint: URL,
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
            "model": "local-model",
            "messages": openAIMessages,
            "stream": true,
            "temperature": 0.7
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        apiKey: String,
        system: String,
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent?alt=sse&key=\(apiKey)") else {
            throw PalmierClientError.upstream("Invalid Google AI endpoint")
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
            throw PalmierClientError.upstream("Google AI API error (\(http.statusCode)): \(errorBody.prefix(300))")
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
