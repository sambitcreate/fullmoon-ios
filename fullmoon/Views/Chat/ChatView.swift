//
//  ChatView.swift
//  fullmoon
//
//  Created by Jordan Singer on 12/3/24.
//

import MarkdownUI
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
        "Create a short, one-line chat title of 6 to 8 words. Reply with only the title."
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
            .navigationTitle(chatTitle)
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
        guard existingTitle.isEmpty else { return }

        let threadID = thread.id
        Task {
            let rawTitle: String
            switch appManager.currentModelSource {
            case .local:
                guard let modelName = appManager.currentModelName else { return }
                rawTitle = await llm.generateTitle(modelName: modelName, thread: thread, systemPrompt: titleSystemPrompt)
            case .cloud:
                guard let modelName = appManager.currentCloudModelName else { return }
                rawTitle = await llm.generateCloudTitle(
                    modelName: modelName,
                    thread: thread,
                    systemPrompt: titleSystemPrompt,
                    apiBaseURL: appManager.cloudAPIBaseURL,
                    apiKey: appManager.cloudAPIKey
                )
            }

            guard let normalizedTitle = normalizeTitle(rawTitle) else { return }
            await MainActor.run {
                guard thread.id == threadID else { return }
                thread.title = normalizedTitle
                try? modelContext.save()
            }
        }
    }

    private func normalizeTitle(_ raw: String) -> String? {
        var cleaned = raw.replacingOccurrences(of: "\n", with: " ")
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

        guard !words.isEmpty else { return nil }
        let limited = words.prefix(8).joined(separator: " ")
        return limited.isEmpty ? nil : limited
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
