# AGENTS.md

This file contains instructions for AI agents working with the fullmoon iOS project.

## Project Overview

Fullmoon is an iOS/macOS application that runs on-device Large Language Models (LLMs) using Apple's MLX framework. It provides a chat interface for interacting with models like Llama 3.2 and Qwen 3.

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
│   │   ├── LLMEvaluator.swift        # LLM generation and evaluation logic
│   │   ├── DeviceStat.swift          # GPU/memory usage tracking
│   │   ├── Models.swift              # Model configurations and registry
│   │   └── RequestLLMIntent.swift     # App Intents integration
│   ├── Views/                         # SwiftUI views
│   │   ├── Chat/                     # Chat interface
│   │   ├── Settings/                 # Settings screens
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

### SwiftData Models

- `Message` - Chat messages with role (user/assistant/system)
- `Thread` - Chat conversations containing multiple messages
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
- `LLMEvaluator` - LLM generation state
- `DeviceStat` - Hardware monitoring

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

## Troubleshooting

### Build Errors

- "No such module 'MLX'" - Ensure dependencies are resolved in Xcode
- "tool 'xcodebuild' requires Xcode" - Run `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`
- SwiftData macro errors - Clean build folder and rebuild

### Runtime Issues

- Model loading fails - Check available memory and disk space
- Generation stops unexpectedly - Check `LLMEvaluator.cancelled` state and memory limits
- App crashes on simulator - MLX doesn't work in simulator, use physical device

## Code Style

- SwiftUI with `@MainActor` for UI classes
- Minimal comments (per project style)
- Swift concurrency patterns (async/await, AsyncStream)
- Environment objects for shared state
- Conditional compilation with `#if os(...)` for platform-specific code
