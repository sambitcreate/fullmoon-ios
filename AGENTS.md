# AGENTS.md

This file contains instructions for AI agents working with the fullmoon iOS project.

## Project Overview

Fullmoon is an iOS/macOS application that runs on-device Large Language Models (LLMs) using Apple's MLX framework, and can also chat with OpenAI-compatible cloud endpoints. It provides a chat interface for interacting with models like Llama 3.2 and Qwen 3, plus custom cloud models.

## Build Commands

### Initial Setup

Ensure Xcode is selected as the active developer directory:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

### Building the Project

```bash
# Build for iOS Simulator
xcodebuild -project fullmoon.xcodeproj -scheme fullmoon -destination 'platform=iOS Simulator,name=iPhone 16' build

# Build for iOS Device (physical device required - MLX requires Metal GPU)
xcodebuild -project fullmoon.xcodeproj -scheme fullmoon -destination 'generic/platform=iOS' build

# Build for macOS
xcodebuild -project fullmoon.xcodeproj -scheme fullmoon -destination 'platform=macOS' build
```

### Running Tests

```bash
xcodebuild test -project fullmoon.xcodeproj -scheme fullmoon -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Cleaning Build Artifacts

```bash
xcodebuild clean -project fullmoon.xcodeproj -scheme fullmoon
```

## Project Structure

```
fullmoon-ios/
├── fullmoon/                          # Main app directory
│   ├── Models/                        # Core model classes
│   │   ├── Data.swift                # AppManager, Message, Thread, enums
│   │   ├── ExaClient.swift            # Exa search client + request/response models
│   │   ├── LLMEvaluator.swift        # LLM generation, evaluation, and agent activities
│   │   ├── DeviceStat.swift          # GPU/memory usage tracking
│   │   ├── OpenAIClient.swift         # OpenAI-compatible API client (models + chat)
│   │   ├── Models.swift              # Model configurations and registry
│   │   ├── ThinkingModePrompt.swift   # System prompt bundle for thinking mode
│   │   └── RequestLLMIntent.swift     # App Intents integration
│   ├── Views/                         # SwiftUI views
│   │   ├── Chat/                     # Chat interface
│   │   ├── Settings/                 # Settings screens
│   │   │   ├── ChatModelsSettingsView.swift # Chat-only model picker (cloud model selector + thinking/search)
│   │   │   └── WebSearchSettingsView.swift # Search toggle + EXA key
│   │   └── Onboarding/               # First-run experience
│   ├── Assets.xcassets/              # Images, colors, etc.
│   └── fullmoonApp.swift            # App entry point
└── fullmoon.xcodeproj/               # Xcode project file
```

## Dependencies

The project uses Swift Package Manager with these key dependencies:

- **MLX** - Apple's machine learning framework
- **MLXLLM** - LLM implementations
- **MLXLMCommon** - Common LLM API
- **SwiftData** - Persistence layer
- **MarkdownUI** - Markdown rendering
- **OpenAI-compatible APIs** - Cloud model listing and chat streaming

Dependencies are managed through Xcode's SPM integration (no Package.swift file at root).

## Key Technologies

- **SwiftUI** - Declarative UI framework
- **SwiftData** - @Model macro for persistence (Message, Thread)
- **App Intents** - Siri/Shortcuts integration
- **@Observable** - State management (LLMEvaluator, DeviceStat)
- **MLX** - On-device ML inference (requires Metal GPU)

## Important Notes

### MLX Framework Requirements

- **Physical device required**: MLX requires Metal GPU and does not work in iOS Simulator
- **Memory management**: The app uses `Memory.cacheLimit` and `Memory.activeMemory` for GPU memory management
- **AsyncStream generation**: Text generation uses AsyncStream-based API for token streaming

### Cloud Models (OpenAI-Compatible)

- **Model source**: `AppManager.currentModelSource` switches between `local` and `cloud`.
- **Endpoint config**: Base URL is used exactly as entered (no automatic `/v1` append). The app calls:
  - `GET {baseURL}/models`
  - `POST {baseURL}/chat/completions` with `stream: true`
- **Model list**: Users can fetch models from the endpoint or add custom model IDs manually.
- **Chat titles**: A short title is generated in parallel using the current model. It uses a non-streaming request (cloud) or a lightweight local generation pass. Result is stored in `Thread.title` and shown in the chat list and nav title when present.

### Search (Exa)

- **Settings**: Search is toggled in Settings and requires an EXA API key.
- **Tools**: Cloud chats expose `web_search`, `exa_search`, and `finalize_answer` tools.
- **Activity display**: Agent activities (thinking, searching) are displayed inline as blockquotes (`> *thinking...*`, `> *searching: query*`).
- **finalize_answer tool**: Models call this tool to explicitly signal completion and submit their final answer.
- **Badge**: Assistant messages show a blue "web search" badge when tools were used.
- **Note**: Search only runs for cloud models; local models ignore the tool loop.

### Thinking Mode

- **Toggle**: Added in the model picker (Models settings).
- **Behavior**: Appends `ThinkingModePrompt.text` to the system prompt for cloud models only.
- **Agentic loop**: Enables extended research with up to 8 tool iterations (can extend to 12 if model is still searching).
- **Normal mode**: Limited to 2 tool iterations for cost control.
- **System prompt**: `AppManager.effectiveSystemPrompt` controls the combined prompt.

### Cloud Model Selector

- **Selector UI**: Cloud model lists use a compact selector (menu for ≤10 models; searchable sheet for >10).
- **Chat model settings**: Chat-only view is trimmed to thinking, search, and cloud model selector.
- **Empty state**: Chat model settings can refresh cloud models and prompts users to verify the endpoint if none are available.

### Agent Activities

- **Activity types**: `AgentActivityType` enum tracks `thinking` and `searching(query: String)` states.
- **Activity list**: `LLMEvaluator.agentActivities` stores activity history during generation.
- **Inline display**: Activities are appended to output as blockquote-style system messages for transparency.
- **UI styling**: Blockquotes use smaller font size (0.85em) and reduced opacity (0.7) for visual distinction.

### SwiftData Models

- `Message` - Chat messages with role (user/assistant/system)
- `Thread` - Chat conversations containing multiple messages
- `Message.usedWebSearch` is optional to support migration from older stores.
- Both use `@Model` macro and `@Attribute(.unique)` for IDs

### API Deprecations (Fixed)

The following APIs have been updated:
- `requestValue()` → `needsValueError()` (App Intents)
- `GPU.snapshot()` → `Memory.snapshot()` (MLX)
- `MLX.GPU.set(cacheLimit:)` → `Memory.cacheLimit` property
- `MLX.GPU.activeMemory` → `Memory.activeMemory`
- `MLXLMCommon.generate(callback:)` → `MLXLMCommon.generate() returns AsyncStream`

### Sendable Conformance

- `Thread` class should NOT explicitly conform to `Sendable` (handled by @Model macro)
- `DeviceStat` uses `@unchecked Sendable` due to mutable state with Timer

## Common Patterns

### Environment Objects

- `AppManager` - App-wide settings and state
- `LLMEvaluator` - LLM generation state and agent activities
- `DeviceStat` - Hardware monitoring

### Empty Chat State

- Shows the current model name under the center icon with matching quaternary styling.

### View Modifiers

Custom `.if()` modifier available for conditional view transformations.

### Platform Checks

Use `appManager.userInterfaceIdiom` for UI adaptation:
- `.phone` - iPhone layout
- `.pad` - iPad layout
- `.mac` - macOS layout
- `.vision` - visionOS layout

## Development Guidelines

1. **Always test on physical devices** - MLX requires Metal GPU
2. **Monitor memory usage** - LLMs are memory-intensive
3. **Use AsyncStream for generation** - Better concurrency support
4. **Follow Swift 6 strict concurrency** - Remove explicit Sendable when unnecessary
5. **Update deprecated APIs** - Check compiler warnings for MLX changes
6. **Throttle scroll updates** - For streaming content, throttle scroll position updates to every 100ms to improve performance

## Troubleshooting

### Build Errors

- "No such module 'MLX'" - Ensure dependencies are resolved in Xcode
- "tool 'xcodebuild' requires Xcode" - Run `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`
- SwiftData macro errors - Clean build folder and rebuild

### Runtime Issues

- Model loading fails - Check available memory and disk space
- Generation stops unexpectedly - Check `LLMEvaluator.cancelled` state and memory limits
- App crashes on simulator - MLX doesn't work in simulator, use physical device
- Cloud model fetch 404s - Verify your base URL path (no automatic `/v1`). Include the correct version path in settings if required by the provider.
- SwiftData migration errors after schema changes - Delete app data on device/simulator or make new fields optional with safe defaults.

## Code Style

- SwiftUI with `@MainActor` for UI classes
- Minimal comments (per project style)
- Swift concurrency patterns (async/await, AsyncStream)
- Environment objects for shared state
- Conditional compilation with `#if os(...)` for platform-specific code
