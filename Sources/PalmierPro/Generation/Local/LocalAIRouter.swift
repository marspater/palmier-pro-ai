import Foundation
import Combine

/// Configurable Local AI Router for Palmier Pro.
/// Routes upscaling and generative requests to local Metal hardware, MLX inference,
/// LM Studio, ComfyUI, or Google AI Pro (Gemini API) cloud fallback.
enum LocalAIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case localMetal = "local_metal"
    case mlxInference = "mlx_inference"
    case lmStudio = "lm_studio"
    case comfyUI = "comfy_ui"
    case googleAI = "google_ai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localMetal: return "Apple Silicon Metal (Local M-Series)"
        case .mlxInference: return "MLX Inference Server (Local Port 8080)"
        case .lmStudio: return "LM Studio Local API (Port 1234)"
        case .comfyUI: return "ComfyUI Local API (Port 8188)"
        case .googleAI: return "Google AI Pro (Gemini API Cloud)"
        }
    }
}

enum ChatAIModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case gemini35Flash = "gemini-3.5-flash"
    case gemini25Flash = "gemini-2.5-flash"
    case veo31Fast = "veo-3.1-fast-generate-001"
    case veo31Lite = "veo-3.1-lite-generate-preview"
    case geminiOmniFlash = "gemini-omni-flash"
    case gemini31FlashImage = "gemini-3.1-flash-image"
    case gemini3ProImage = "gemini-3-pro-image"
    case claudeSonnet = "claude-3-5-sonnet"
    case claudeHaiku = "claude-3-5-haiku"
    case gpt4o = "gpt-4o"
    case lmStudio = "lm-studio"
    case mlx = "mlx"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini35Flash: return "Google Gemini 3.5 Flash (Recommended)"
        case .gemini25Flash: return "Google Gemini 2.5 Flash (Video Analysis)"
        case .veo31Fast: return "Google Veo 3.1 Fast (Video Generation)"
        case .veo31Lite: return "Google Veo 3.1 Lite (Preview Video)"
        case .geminiOmniFlash: return "Google Gemini Omni Flash (Media Gen & Edit)"
        case .gemini31FlashImage: return "Google Gemini 3.1 Flash Image (Nano Banana 2)"
        case .gemini3ProImage: return "Google Gemini 3 Pro Image (Nano Banana Pro)"
        case .claudeSonnet: return "Anthropic Claude 3.5 Sonnet"
        case .claudeHaiku: return "Anthropic Claude 3.5 Haiku"
        case .gpt4o: return "OpenAI / OpenRouter GPT-4o"
        case .lmStudio: return "LM Studio Local (Port 1234)"
        case .mlx: return "MLX Local (Port 8080)"
        }
    }

    var shortName: String {
        switch self {
        case .gemini35Flash: return "Gemini 3.5 Flash"
        case .gemini25Flash: return "Gemini 2.5 Flash"
        case .veo31Fast: return "Veo 3.1 Fast"
        case .veo31Lite: return "Veo 3.1 Lite"
        case .geminiOmniFlash: return "Gemini Omni"
        case .gemini31FlashImage: return "Gemini 3.1 Image"
        case .gemini3ProImage: return "Gemini 3 Pro Image"
        case .claudeSonnet: return "Claude 3.5 Sonnet"
        case .claudeHaiku: return "Claude 3.5 Haiku"
        case .gpt4o: return "GPT-4o"
        case .lmStudio: return "LM Studio"
        case .mlx: return "MLX Local"
        }
    }

    var iconName: String {
        switch self {
        case .gemini35Flash, .gemini25Flash, .geminiOmniFlash: return "sparkles"
        case .veo31Fast, .veo31Lite: return "film"
        case .gemini31FlashImage, .gemini3ProImage: return "photo"
        case .claudeSonnet, .claudeHaiku: return "brain"
        case .gpt4o: return "bolt"
        case .lmStudio, .mlx: return "cpu"
        }
    }

    /// Sanitizes model string to remove vendor prefixes like "google/" or "models/"
    static func sanitize(modelString: String) -> String {
        var str = modelString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.lowercased().hasPrefix("google/") {
            str = String(str.dropFirst("google/".count))
        }
        if str.lowercased().hasPrefix("models/") {
            str = String(str.dropFirst("models/".count))
        }
        return str
    }
}

@MainActor
final class LocalAIRouter: ObservableObject {
    static let shared = LocalAIRouter()

    private enum Keys {
        static let activeProvider = "PalmierLocalAIActiveProvider"
        static let mlxEndpoint = "PalmierLocalAIMLXEndpoint"
        static let lmStudioEndpoint = "PalmierLocalAILMStudioEndpoint"
        static let comfyEndpoint = "PalmierLocalAIComfyEndpoint"
        static let googleAIKey = "PalmierGoogleAIAPIKey"
        static let customGeminiModel = "PalmierCustomGeminiModel"
        static let anthropicAPIKey = "PalmierAnthropicAPIKey"
        static let openAIAPIKey = "PalmierOpenAIAPIKey"
        static let selectedChatModel = "PalmierSelectedChatModel"
    }

    @Published var activeProvider: LocalAIProvider {
        didSet { UserDefaults.standard.set(activeProvider.rawValue, forKey: Keys.activeProvider) }
    }

    @Published var selectedChatModel: ChatAIModel {
        didSet { UserDefaults.standard.set(selectedChatModel.rawValue, forKey: Keys.selectedChatModel) }
    }

    @Published var customGeminiModel: String {
        didSet {
            let sanitized = ChatAIModel.sanitize(modelString: customGeminiModel)
            UserDefaults.standard.set(sanitized, forKey: Keys.customGeminiModel)
        }
    }

    @Published var mlxEndpoint: String {
        didSet { UserDefaults.standard.set(mlxEndpoint, forKey: Keys.mlxEndpoint) }
    }

    @Published var lmStudioEndpoint: String {
        didSet { UserDefaults.standard.set(lmStudioEndpoint, forKey: Keys.lmStudioEndpoint) }
    }

    @Published var comfyEndpoint: String {
        didSet { UserDefaults.standard.set(comfyEndpoint, forKey: Keys.comfyEndpoint) }
    }

    @Published var googleAIKey: String {
        didSet { UserDefaults.standard.set(googleAIKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.googleAIKey) }
    }

    @Published var anthropicAPIKey: String {
        didSet { UserDefaults.standard.set(anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.anthropicAPIKey) }
    }

    @Published var openAIAPIKey: String {
        didSet { UserDefaults.standard.set(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.openAIAPIKey) }
    }

    private var lastGoogleAIRequestDate: Date?

    private init() {
        let savedProvider = UserDefaults.standard.string(forKey: Keys.activeProvider)
            .flatMap { LocalAIProvider(rawValue: $0) } ?? .localMetal
        let savedChatModel = UserDefaults.standard.string(forKey: Keys.selectedChatModel)
            .flatMap { ChatAIModel(rawValue: $0) } ?? .gemini35Flash
        let savedCustomGemini = UserDefaults.standard.string(forKey: Keys.customGeminiModel) ?? "gemini-3.5-flash"
        let savedMLX = UserDefaults.standard.string(forKey: Keys.mlxEndpoint) ?? "http://localhost:8080"
        let savedLMStudio = UserDefaults.standard.string(forKey: Keys.lmStudioEndpoint) ?? "http://localhost:1234/v1"
        let savedComfy = UserDefaults.standard.string(forKey: Keys.comfyEndpoint) ?? "http://127.0.0.1:8188"
        let savedGoogleKey = UserDefaults.standard.string(forKey: Keys.googleAIKey) ?? ""
        let savedAnthropicKey = UserDefaults.standard.string(forKey: Keys.anthropicAPIKey) ?? ""
        let savedOpenAIKey = UserDefaults.standard.string(forKey: Keys.openAIAPIKey) ?? ""

        self.activeProvider = savedProvider
        self.selectedChatModel = savedChatModel
        self.customGeminiModel = ChatAIModel.sanitize(modelString: savedCustomGemini)
        self.mlxEndpoint = savedMLX
        self.lmStudioEndpoint = savedLMStudio
        self.comfyEndpoint = savedComfy
        self.googleAIKey = savedGoogleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anthropicAPIKey = savedAnthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openAIAPIKey = savedOpenAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enforces a minimum interval (2.5s) between Google AI Studio requests to prevent 429 domino retries.
    func throttleGoogleAIRequest() async {
        if let lastDate = lastGoogleAIRequestDate {
            let elapsed = Date().timeIntervalSince(lastDate)
            if elapsed < 2.5 {
                let sleepNanoseconds = UInt64((2.5 - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            }
        }
        lastGoogleAIRequestDate = Date()
    }

    // MARK: - Upscale Dispatch

    /// Dispatches an upscale request to the local Metal engine or configured provider.
    func processUpscale(
        sourceURL: URL,
        outputURL: URL,
        scaleFactor: CGFloat = 2.0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        // Upscaling defaults to local Metal hardware for zero latency
        return try await LocalUpscaleEngine.shared.upscale(
            inputURL: sourceURL,
            outputURL: outputURL,
            scaleFactor: scaleFactor,
            progress: progress
        )
    }

    // MARK: - Generative Dispatch & Fallback

    /// Generates content locally or via Google AI Pro fallback
    func processGeneration(
        prompt: String,
        model: String,
        assetType: ClipType
    ) async throws -> String {
        switch activeProvider {
        case .localMetal, .mlxInference:
            return try await queryLocalServer(endpoint: "\(mlxEndpoint)/v1/generate", prompt: prompt, model: model)
        case .lmStudio:
            return try await queryLMStudio(prompt: prompt, model: model)
        case .comfyUI:
            return try await queryComfyUI(prompt: prompt)
        case .googleAI:
            return try await queryGoogleAI(prompt: prompt)
        }
    }

    private func queryLocalServer(endpoint: String, prompt: String, model: String) async throws -> String {
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["prompt": prompt, "model": model]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        if let responseString = String(data: data, encoding: .utf8) {
            return responseString
        }
        throw URLError(.cannotParseResponse)
    }

    private func queryLMStudio(prompt: String, model: String) async throws -> String {
        let endpoint = "\(lmStudioEndpoint)/chat/completions"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model.isEmpty ? "local-model" : model,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        throw URLError(.cannotParseResponse)
    }

    private func queryComfyUI(prompt: String) async throws -> String {
        let endpoint = "\(comfyEndpoint)/prompt"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["prompt": ["3": ["inputs": ["text": prompt], "class_type": "CLIPTextEncode"]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let promptId = json["prompt_id"] as? String {
            return promptId
        }
        throw URLError(.cannotParseResponse)
    }

    private func queryGoogleAI(prompt: String) async throws -> String {
        guard !googleAIKey.isEmpty else {
            throw NSError(domain: "LocalAIRouter", code: 401, userInfo: [NSLocalizedDescriptionKey: "Google AI API Key missing. Please set it in Settings -> Models."])
        }
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(googleAIKey)"
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let candidates = json["candidates"] as? [[String: Any]],
           let content = candidates.first?["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]],
           let text = parts.first?["text"] as? String {
            return text
        }
        throw URLError(.cannotParseResponse)
    }
}
