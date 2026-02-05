//
//  ChatView.swift
//  fullmoon
//
//  Created by Jordan Singer on 12/3/24.
//

import MarkdownUI
import OSLog
import SwiftUI

struct ChatView: View {
    @EnvironmentObject var appManager: AppManager
    @Environment(\.modelContext) var modelContext
    @Binding var currentThread: Thread?
    @Environment(LLMEvaluator.self) var llm
    @Namespace var bottomID
    @State var showModelPicker = false
    @State var prompt = ""
    @FocusState.Binding var isPromptFocused: Bool
    @Binding var showChats: Bool
    @Binding var showSettings: Bool
    
    @State var thinkingTime: TimeInterval?
    
    @State private var generatingThreadID: UUID?
    @State private var displayedTitle: String = "chat"
    @State private var titleOpacity: Double = 1.0
    private static let titleLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "fullmoon",
        category: "TitleGeneration"
    )

    var isPromptEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    let platformBackgroundColor: Color = {
        #if os(iOS)
        return Color(UIColor.secondarySystemBackground)
        #elseif os(visionOS)
        return Color(UIColor.separator)
        #elseif os(macOS)
        return Color(NSColor.secondarySystemFill)
        #endif
    }()

    var chatInput: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField("message", text: $prompt, axis: .vertical)
                .focused($isPromptFocused)
                .textFieldStyle(.plain)
            #if os(iOS) || os(visionOS)
                .padding(.horizontal, 16)
            #elseif os(macOS)
                .padding(.horizontal, 12)
                .onSubmit {
                    handleShiftReturn()
                }
                .submitLabel(.send)
            #endif
                .padding(.vertical, 8)
            #if os(iOS) || os(visionOS)
                .frame(minHeight: 48)
            #elseif os(macOS)
                .frame(minHeight: 32)
            #endif
            #if os(iOS)
            .onSubmit {
                isPromptFocused = true
                generate()
            }
            #endif

            if llm.running {
                stopButton
            } else {
                generateButton
            }
        }
        #if os(iOS) || os(visionOS)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(platformBackgroundColor)
        )
        #elseif os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(platformBackgroundColor)
        )
        #endif
    }

    var modelPickerButton: some View {
        Button {
            appManager.playHaptic()
            showModelPicker.toggle()
        } label: {
            Group {
                Image(systemName: "chevron.up")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                #if os(iOS) || os(visionOS)
                    .frame(width: 16)
                #elseif os(macOS)
                    .frame(width: 12)
                #endif
                    .tint(.primary)
            }
            #if os(iOS) || os(visionOS)
            .frame(width: 48, height: 48)
            #elseif os(macOS)
            .frame(width: 32, height: 32)
            #endif
            .background(
                Circle()
                    .fill(platformBackgroundColor)
            )
        }
        #if os(macOS) || os(visionOS)
        .buttonStyle(.plain)
        #endif
    }

    var generateButton: some View {
        Button {
            generate()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
            #if os(iOS) || os(visionOS)
                .frame(width: 24, height: 24)
            #else
                .frame(width: 16, height: 16)
            #endif
        }
        .disabled(isPromptEmpty)
        #if os(iOS) || os(visionOS)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        #else
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        #endif
        #if os(macOS) || os(visionOS)
        .buttonStyle(.plain)
        #endif
    }

    var stopButton: some View {
        Button {
            llm.stop()
        } label: {
            Image(systemName: "stop.circle.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
            #if os(iOS) || os(visionOS)
                .frame(width: 24, height: 24)
            #else
                .frame(width: 16, height: 16)
            #endif
        }
        .disabled(llm.cancelled)
        #if os(iOS) || os(visionOS)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        #else
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        #endif
        #if os(macOS) || os(visionOS)
        .buttonStyle(.plain)
        #endif
    }

    var chatTitle: String {
        if let currentThread = currentThread {
            let trimmedTitle = currentThread.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }
            if let firstMessage = currentThread.sortedMessages.first {
                return firstMessage.content
            }
        }

        return "chat"
    }

    private var titleSystemPrompt: String {
        """
        You are a title generator. You output ONLY a JSON object with a "title" field. Nothing else.

        Generate a brief title that helps the user find this conversation later.

        OUTPUT FORMAT: {"title": "Your title here"}

        RULES:
        - Output MUST be valid JSON starting with { and ending with }
        - Title must be 3-8 words, single line, ≤50 characters
        - Title must be grammatically correct and read naturally
        - Use the same language as the user message
        - Focus on the main topic or question
        - Keep exact: technical terms, numbers, filenames
        - Remove filler words: the, this, my, a, an
        - NO markdown formatting (no **, no `)
        - NO explanations or reasoning
        - NO numbered steps (1. 2. 3.)
        - NEVER start with "Analyze", "Identify", "Determine"
        - NEVER say you cannot generate a title
        - Always output something meaningful

        EXAMPLES:
        User asks about debugging → {"title": "Debugging production errors"}
        User asks about React → {"title": "React hooks best practices"}
        User asks about database → {"title": "Postgres connection setup"}
        User says hello → {"title": "Quick greeting"}
        User asks about football → {"title": "Best football players"}

        Output the JSON now:
        """
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let currentThread = currentThread {
                    ConversationView(thread: currentThread, generatingThreadID: generatingThreadID)
                } else {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: appManager.getMoonPhaseIcon())
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                        Text(appManager.currentModelDisplayName.isEmpty ? "model" : appManager.currentModelDisplayName)
                            .font(.footnote)
                    }
                    .foregroundStyle(.quaternary)
                    Spacer()
                }

                HStack(alignment: .bottom) {
                    modelPickerButton
                    chatInput
                }
                .padding()
            }
            .navigationTitle(displayedTitle)
            .opacity(titleOpacity)
            #if os(iOS) || os(visionOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .sheet(isPresented: $showModelPicker) {
                    NavigationStack {
                        ChatModelsSettingsView()
                            .environment(llm)
                        #if os(visionOS)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: { showModelPicker.toggle() }) {
                                        Image(systemName: "xmark")
                                    }
                                }
                            }
                        #endif
                    }
                    #if os(iOS)
                    .presentationDragIndicator(.visible)
                    .if(appManager.userInterfaceIdiom == .phone) { view in
                        view.presentationDetents([.fraction(0.4)])
                    }
                    #elseif os(macOS)
                    .toolbar {
                        ToolbarItem(placement: .destructiveAction) {
                            Button(action: { showModelPicker.toggle() }) {
                                Text("close")
                            }
                        }
                    }
                    #endif
                }
                .toolbar {
                    #if os(iOS) || os(visionOS)
                    if appManager.userInterfaceIdiom == .phone {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(action: {
                                appManager.playHaptic()
                                showChats.toggle()
                            }) {
                                Image(systemName: "list.bullet")
                            }
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            appManager.playHaptic()
                            showSettings.toggle()
                        }) {
                            Image(systemName: "gear")
                        }
                    }
                    #elseif os(macOS)
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            appManager.playHaptic()
                            showSettings.toggle()
                        }) {
                            Label("settings", systemImage: "gear")
                        }
                    }
                    #endif
                }
        }
        .onAppear {
            displayedTitle = chatTitle
            titleOpacity = 1.0
        }
        .onChange(of: chatTitle) { _, newValue in
            guard newValue != displayedTitle else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                titleOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                displayedTitle = newValue
                withAnimation(.easeIn(duration: 0.2)) {
                    titleOpacity = 1.0
                }
            }
        }
    }

    private func generate() {
        if !isPromptEmpty {
            if currentThread == nil {
                let newThread = Thread()
                currentThread = newThread
                modelContext.insert(newThread)
                try? modelContext.save()
            }

            if let currentThread = currentThread {
                generatingThreadID = currentThread.id
                Task {
                    let message = prompt
                    prompt = ""
                    appManager.playHaptic()
                    sendMessage(Message(role: .user, content: message, thread: currentThread))
                    startTitleGenerationIfNeeded(for: currentThread)
                    isPromptFocused = true
                    switch appManager.currentModelSource {
                    case .local:
                        guard let modelName = appManager.currentModelName else {
                            sendMessage(Message(role: .assistant, content: "No local model selected. Choose a model in settings.", thread: currentThread))
                            generatingThreadID = nil
                            return
                        }
                        let output = await llm.generate(modelName: modelName, thread: currentThread, systemPrompt: appManager.effectiveSystemPrompt)
                        sendMessage(Message(role: .assistant, content: output, thread: currentThread, generatingTime: llm.thinkingTime))
                        generatingThreadID = nil
                    case .cloud:
                        guard let modelName = appManager.currentCloudModelName else {
                            sendMessage(Message(role: .assistant, content: "No cloud model selected. Choose a model in settings.", thread: currentThread))
                            generatingThreadID = nil
                            return
                        }
                        let output = await llm.generateCloud(
                            modelName: modelName,
                            thread: currentThread,
                            systemPrompt: appManager.effectiveSystemPrompt,
                            apiBaseURL: appManager.cloudAPIBaseURL,
                            apiKey: appManager.cloudAPIKey,
                            webSearchEnabled: appManager.webSearchEnabled,
                            exaAPIKey: appManager.exaAPIKey,
                            thinkingModeEnabled: appManager.thinkingModeEnabled
                        )
                        sendMessage(Message(
                            role: .assistant,
                            content: output,
                            thread: currentThread,
                            generatingTime: llm.thinkingTime,
                            usedWebSearch: llm.lastUsedWebSearch
                        ))
                        generatingThreadID = nil
                    }
                }
            }
        }
    }

    private func sendMessage(_ message: Message) {
        appManager.playHaptic()
        modelContext.insert(message)
        try? modelContext.save()
    }

    private func startTitleGenerationIfNeeded(for thread: Thread) {
        let existingTitle = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existingTitle.isEmpty {
            Self.titleLogger.debug(
                "Skipping title generation for thread=\(thread.id.uuidString, privacy: .public); existing title=\(existingTitle, privacy: .public)"
            )
            return
        }

        let threadID = thread.id
        let fallback = fallbackTitle(for: thread)
        if let fallback, !fallback.isEmpty {
            Self.titleLogger.debug(
                "Applying immediate fallback title for thread=\(threadID.uuidString, privacy: .public): \(fallback, privacy: .public)"
            )
            thread.title = fallback
            try? modelContext.save()
        } else {
            Self.titleLogger.debug(
                "No fallback title available for thread=\(threadID.uuidString, privacy: .public)"
            )
        }

        Task {
            Self.titleLogger.info(
                "Starting title generation thread=\(threadID.uuidString, privacy: .public) source=\(appManager.currentModelSource.rawValue, privacy: .public)"
            )
            let rawTitle: String
            switch appManager.currentModelSource {
            case .local:
                guard let modelName = appManager.currentModelName else {
                    Self.titleLogger.error(
                        "Title generation aborted thread=\(threadID.uuidString, privacy: .public); missing local model"
                    )
                    return
                }
                rawTitle = await llm.generateTitle(modelName: modelName, thread: thread, systemPrompt: titleSystemPrompt)
            case .cloud:
                guard let modelName = appManager.currentCloudModelName else {
                    Self.titleLogger.error(
                        "Title generation aborted thread=\(threadID.uuidString, privacy: .public); missing cloud model"
                    )
                    return
                }
                rawTitle = await llm.generateCloudTitle(
                    modelName: modelName,
                    thread: thread,
                    systemPrompt: titleSystemPrompt,
                    apiBaseURL: appManager.cloudAPIBaseURL,
                    apiKey: appManager.cloudAPIKey
                )
            }

            Self.titleLogger.debug(
                "Raw title response thread=\(threadID.uuidString, privacy: .public) chars=\(rawTitle.count, privacy: .public) preview=\(previewForLog(rawTitle), privacy: .public)"
            )

            guard let normalizedTitle = normalizeTitle(rawTitle) else {
                Self.titleLogger.debug(
                    "Normalized title is empty for thread=\(threadID.uuidString, privacy: .public); keeping fallback/current title"
                )
                return
            }
            guard isMeaningfulGeneratedTitle(normalizedTitle, context: "generated") else {
                Self.titleLogger.debug(
                    "Rejected generated title for thread=\(threadID.uuidString, privacy: .public): \(normalizedTitle, privacy: .public)"
                )
                return
            }
            await MainActor.run {
                guard thread.id == threadID else { return }
                let currentTitle = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let shouldReplace =
                    currentTitle.isEmpty ||
                    (fallback?.caseInsensitiveCompare(currentTitle) == .orderedSame) ||
                    !isMeaningfulGeneratedTitle(currentTitle, context: "current")
                guard shouldReplace else {
                    Self.titleLogger.debug(
                        "Preserving current title for thread=\(threadID.uuidString, privacy: .public): \(currentTitle, privacy: .public)"
                    )
                    return
                }
                thread.title = normalizedTitle
                try? modelContext.save()
                Self.titleLogger.info(
                    "Saved generated title for thread=\(threadID.uuidString, privacy: .public): \(normalizedTitle, privacy: .public)"
                )
            }
        }
    }

    private func fallbackTitle(for thread: Thread) -> String? {
        guard let firstUserMessage = thread.sortedMessages.first(where: { $0.role == .user })?.content else {
            return nil
        }
        let cleaned = firstUserMessage
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let words = cleaned.split { $0.isWhitespace }.map(String.init)
        guard !words.isEmpty else { return nil }
        return words.prefix(8).joined(separator: " ")
    }

    private func normalizeTitle(_ raw: String) -> String? {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            Self.titleLogger.debug("normalizeTitle: raw title is empty")
            return nil
        }

        let extracted = extractJSONTitle(from: raw) ?? raw
        let usedJSONExtraction = extracted != raw
        Self.titleLogger.debug(
            "normalizeTitle: jsonExtraction=\(usedJSONExtraction, privacy: .public) rawChars=\(raw.count, privacy: .public) extractedChars=\(extracted.count, privacy: .public)"
        )
        var cleaned = stripReasoningPreamble(from: extracted)
        cleaned = cleaned.replacingOccurrences(of: "\n", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\r", with: " ")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))

        let lowercased = cleaned.lowercased()
        if lowercased.hasPrefix("title:") {
            cleaned = String(cleaned.dropFirst("title:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let words = cleaned
            .split { $0.isWhitespace }
            .map(String.init)

        guard !words.isEmpty else {
            Self.titleLogger.debug(
                "normalizeTitle: no words after cleaning; extractedPreview=\(previewForLog(extracted), privacy: .public)"
            )
            return nil
        }
        let limited = words.prefix(8).joined(separator: " ")
        Self.titleLogger.debug(
            "normalizeTitle: result=\(limited, privacy: .public)"
        )
        return limited.isEmpty ? nil : limited
    }

    private func isMeaningfulGeneratedTitle(_ title: String, context: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Self.titleLogger.debug("Rejected \(context, privacy: .public) title: empty")
            return false
        }
        guard !looksLikeReasoningArtifact(trimmed, context: context) else { return false }

        let lower = trimmed.lowercased()
        let disallowed = [
            "chat",
            "new chat",
            "conversation",
            "untitled",
            "title",
            "string",
            "json",
            "object",
            "response",
            "output",
            "text",
            "n/a",
            "none",
            "null",
            "undefined"
        ]
        if disallowed.contains(lower) {
            Self.titleLogger.debug(
                "Rejected \(context, privacy: .public) title: generic value=\(trimmed, privacy: .public)"
            )
            return false
        }

        let disallowedPrefixes = [
            "the user",
            "user is",
            "user wants",
            "i should",
            "i need to",
            "assistant",
            "as an ai",
            "the prompt"
        ]
        if disallowedPrefixes.contains(where: { lower.hasPrefix($0) }) {
            Self.titleLogger.debug(
                "Rejected \(context, privacy: .public) title: disallowed prefix value=\(trimmed, privacy: .public)"
            )
            return false
        }

        let disallowedFragments = [
            " asking me ",
            " asked me ",
            " wants me to ",
            " request is ",
            " this request ",
            " me for an opinion "
        ]
        if disallowedFragments.contains(where: { lower.contains($0) }) {
            Self.titleLogger.debug(
                "Rejected \(context, privacy: .public) title: disallowed fragment value=\(trimmed, privacy: .public)"
            )
            return false
        }

        let words = trimmed.split { $0.isWhitespace }
        if words.isEmpty {
            Self.titleLogger.debug("Rejected \(context, privacy: .public) title: no words")
            return false
        }

        // Reject schema placeholders such as "title string", "title here", etc.
        let placeholderFragments = [
            "title here",
            "your title",
            "example title",
            "insert title",
            "return json",
            "json object",
            "schema"
        ]
        if placeholderFragments.contains(where: { lower.contains($0) }) {
            Self.titleLogger.debug(
                "Rejected \(context, privacy: .public) title: schema placeholder value=\(trimmed, privacy: .public)"
            )
            return false
        }

        return true
    }

    private func looksLikeReasoningArtifact(_ text: String, context: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Self.titleLogger.debug("Rejected \(context, privacy: .public) title: blank after trim")
            return true
        }

        // Common leaked formatting from reasoning/tool outputs.
        if trimmed.contains("**") || trimmed.contains("```") || trimmed.contains("`") {
            Self.titleLogger.debug(
                "Rejected \(context, privacy: .public) title: markdown artifact value=\(trimmed, privacy: .public)"
            )
            return true
        }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") {
            Self.titleLogger.debug(
                "Rejected \(context, privacy: .public) title: heading/blockquote artifact value=\(trimmed, privacy: .public)"
            )
            return true
        }
        if trimmed.hasSuffix(":") {
            Self.titleLogger.debug(
                "Rejected \(context, privacy: .public) title: trailing colon value=\(trimmed, privacy: .public)"
            )
            return true
        }

        // Reject ordered-list headings like "1. Analyze..."
        if let listRegex = try? NSRegularExpression(pattern: #"^\s*\d+[\.\)]\s+"#, options: []),
           listRegex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
            Self.titleLogger.debug(
                "Rejected \(context, privacy: .public) title: ordered-list artifact value=\(trimmed, privacy: .public)"
            )
            return true
        }

        let lower = trimmed.lowercased()
        let metaPhrases = [
            "analyze the request",
            "analysis:",
            "reasoning:",
            "the user wants",
            "the user is asking",
            "i should",
            "i need to",
            "let me ",
            "step by step",
            "constraints",
            "requirements",
            "tool call",
            "final answer"
        ]
        if metaPhrases.contains(where: { lower.contains($0) }) {
            Self.titleLogger.debug(
                "Rejected \(context, privacy: .public) title: meta phrase value=\(trimmed, privacy: .public)"
            )
            return true
        }

        return false
    }

    private func previewForLog(_ text: String, maxLength: Int = 140) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > maxLength else { return compact }
        return String(compact.prefix(maxLength)) + "..."
    }

    private func extractJSONTitle(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = object["title"] as? String {
            return title
        }

        // Fallback: try to locate a JSON object in the text.
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") {
            let slice = String(raw[start...end])
            if let sliceData = slice.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: sliceData) as? [String: Any],
               let title = object["title"] as? String {
                return title
            }
        }

        return nil
    }

    private func stripReasoningPreamble(from text: String) -> String {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return raw }

        let markers = ["title:", "chat title:", "final title:", "suggested title:"]
        let lower = raw.lowercased()
        if let range = markers.compactMap({ marker in
            lower.range(of: marker, options: [.caseInsensitive, .backwards])
        }).first {
            let start = raw.index(raw.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
            let candidate = String(raw[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }

        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.count > 1 {
            let filtered = lines.filter { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedLine.hasPrefix("1.") || trimmedLine.hasPrefix("2.") || trimmedLine.hasPrefix("3.") { return false }
                if trimmedLine.hasPrefix("-") || trimmedLine.hasPrefix("*") { return false }
                let stripped = trimmedLine.trimmingCharacters(in: CharacterSet(charactersIn: "*-•\"'“”‘’ "))
                let lowerLine = stripped.lowercased()
                if lowerLine.hasPrefix("analyze") { return false }
                if lowerLine.hasPrefix("analyze the request") { return false }
                if lowerLine.hasPrefix("the user wants") { return false }
                if lowerLine.hasPrefix("constraints") { return false }
                if lowerLine.hasPrefix("constraint") { return false }
                if lowerLine.hasPrefix("requirement") { return false }
                if lowerLine.hasPrefix("analysis") { return false }
                if lowerLine.hasPrefix("reasoning") { return false }
                return true
            }
            if let candidate = filtered.last {
                return candidate
            }
        }

        return raw
    }

    #if os(macOS)
    private func handleShiftReturn() {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            prompt.append("\n")
            isPromptFocused = true
        } else {
            generate()
        }
    }
    #endif
}

#Preview {
    @FocusState var isPromptFocused: Bool
    ChatView(currentThread: .constant(nil), isPromptFocused: $isPromptFocused, showChats: .constant(false), showSettings: .constant(false))
}
