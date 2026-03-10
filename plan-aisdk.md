# Swift AI SDK Integration Plan

## Current State

**fullmoon-iOS** currently uses **MLX** (Apple's on-device ML framework) for local LLM inference:

- **Models**: Downloads from mlx-community (Llama 3.2, DeepSeek R1, Qwen 3)
- **Configuration**: `ModelConfiguration` in `Models.swift` defines available models
- **Inference**: `LLMEvaluator.swift` handles loading and text generation via MLXLLM
- **No external endpoints**: Currently has no cloud/API-based AI configuration

## Swift AI SDK Overview

The [Swift AI SDK](https://github.com/teunlao/swift-ai-sdk) is a unified AI SDK for Swift, bringing Vercel AI SDK capabilities to Apple platforms:

- **37+ providers**: OpenAI, Anthropic, Google, Groq, xAI, TogetherAI, and more
- **Streaming & non-streaming** text generation
- **Structured outputs** (Codable/JSON Schema)
- **Tool/function calling** + MCP tools
- **Provider-agnostic API** - swap providers without changing call sites
- **Middleware hooks**

## Integration Plan

### Phase 1: Package Integration

1. **Add Swift AI SDK dependencies** to `project.pbxproj`:
   ```swift
   // SwiftAISDK core
   .product(name: "SwiftAISDK", package: "swift-ai-sdk")
   // Provider packages (choose based on desired providers)
   .product(name: "OpenAIProvider", package: "swift-ai-sdk")
   .product(name: "AnthropicProvider", package: "swift-ai-sdk")
   .product(name: "GoogleProvider", package: "swift-ai-sdk")
   ```

2. **Supported providers** (add as needed):
   - `OpenAIProvider` - GPT-4o, GPT-5
   - `AnthropicProvider` - Claude 4, Claude 3.5
   - `GoogleProvider` - Gemini 2.5
   - `GroqProvider` - Fast inference
   - `TogetherAIProvider` - Open models
   - `XAIProvider` - xAI Grok

### Phase 2: Provider Configuration Model

Add new configuration models in `Models.swift` or new file `ProviderConfiguration.swift`:

```swift
enum AIProvider: String, CaseIterable {
    case local      // Current MLX
    case openAI
    case anthropic
    case google
    case groq
    // etc.
}

struct ProviderConfig {
    let provider: AIProvider
    let modelName: String
    let apiKey: String?
    let baseURL: String?  // For custom endpoints
}
```

### Phase 3: Settings UI Updates

Update `SettingsView.swift` and create `ProviderSettingsView.swift`:

1. **Provider selector**: Choose between Local/Cloud
2. **API key input**: Secure text field for API keys (store in Keychain)
3. **Model selector**: Dropdown based on selected provider
4. **Endpoint URL**: For custom/OAI-compatible endpoints

### Phase 4: LLM Evaluator Refactor

Refactor `LLMEvaluator.swift` to support both modes:

```swift
enum LLMMode {
    case local(modelName: String)
    case cloud(provider: AIProvider, model: String)
}

@Observable
class LLMEvaluator {
    // Existing local inference properties...
    
    // New cloud properties
    var llmMode: LLMMode = .local(modelName: "mlx-community/...")
    var apiKey: String?
    
    // Unified generate method
    func generate(prompt: String) async -> String {
        switch llmMode {
        case .local(let modelName):
            return await generateLocal(modelName: modelName, prompt: prompt)
        case .cloud(let provider, let model):
            return await generateCloud(provider: provider, model: model, prompt: prompt)
        }
    }
    
    private func generateCloud(provider: AIProvider, model: String, prompt: String) async -> String {
        // Use Swift AI SDK
    }
}
```

### Phase 5: Streaming Support

Implement streaming responses using Swift AI SDK's `streamText`:

```swift
func streamGenerate(prompt: String) -> AsyncStream<String> {
    AsyncStream { continuation in
        Task {
            let stream = try streamText(
                model: openai("gpt-5"),
                prompt: prompt
            )
            
            for try await delta in stream.textStream {
                continuation.yield(delta)
            }
            
            continuation.finish()
        }
    }
}
```

### Phase 6: Advanced Features (Optional)

1. **Structured outputs**: Use `generateObject()` for typed responses
2. **Tool calling**: Implement weather, calculator, search tools
3. **Middleware**: Add request/response logging hooks
4. **Fallback logic**: Try cloud if local fails, or vice versa

## Implementation Steps

| Step | File(s) | Description |
|------|---------|-------------|
| 1 | `project.pbxproj` | Add Swift AI SDK packages |
| 2 | `Models/ProviderConfig.swift` | New provider configuration model |
| 3 | `Models/LLMEvaluator.swift` | Add cloud generation methods |
| 4 | `Views/Settings/ProviderSettingsView.swift` | New provider settings UI |
| 5 | `Views/Settings/SettingsView.swift` | Add provider settings navigation |
| 6 | `Models/Data.swift` | Store API keys in Keychain |

## Keychain Security

API keys should be stored securely using Keychain:

```swift
// Store
KeychainHelper.save(apiKey, forKey: "openai_api_key")

// Retrieve  
let apiKey = KeychainHelper.load(forKey: "openai_api_key")
```

## Backward Compatibility

- **Default to local**: Keep MLX as default; cloud is opt-in
- **Graceful degradation**: If cloud fails, fall back to local
- **User choice**: Clear UI to toggle between local/cloud

## Example Usage After Integration

```swift
// Switch to cloud provider
llm.llmMode = .cloud(provider: .openAI, model: "gpt-5")

// Generate (streaming)
for try await token in llm.streamGenerate(prompt: "Hello!") {
    output += token
}

// Structured output
let summary = try await llm.generateObject(
    schema: Summary.self,
    prompt: "Summarize this article"
)
```

## Notes

- Swift AI SDK requires iOS 15+ / macOS 12+
- API keys are user-provided (no built-in keys)
- Consider usage costs for cloud providers
- Local MLX inference remains free and private
