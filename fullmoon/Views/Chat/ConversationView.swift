//
//  ConversationView.swift
//  fullmoon
//
//  Created by Xavier on 16/12/2024.
//

import MarkdownUI
import SwiftUI

struct AnimatedActivityView: View {
    let activity: AgentActivity
    @State private var opacity: Double = 0
    @State private var offset: CGFloat = 20
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.secondary)
                .frame(width: 4, height: 4)
            
            Text(activity.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        }
        .opacity(opacity)
        .offset(y: offset)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) {
                opacity = 0.7
                offset = 0
            }
        }
        .transition(.asymmetric(
            insertion: .offset(y: 20).combined(with: .opacity),
            removal: .offset(y: -20).combined(with: .opacity)
        ))
    }
}

struct FadingMarkdownBlock: View {
    let text: String
    let delay: Double
    let initialDelay: Double
    
    @State private var opacity: Double = 0
    @State private var offset: CGFloat = 5
    
    var body: some View {
        Markdown(text)
            .textSelection(.enabled)
            .opacity(opacity)
            .offset(y: offset)
            .onAppear {
                withAnimation(.easeOut(duration: 0.2).delay(initialDelay + delay)) {
                    opacity = 1.0
                    offset = 0
                }
            }
    }
}

struct FadeInMessageView: View {
    let message: Message
    @State private var opacity: Double = 0
    @State private var offset: CGFloat = 5
    
    var body: some View {
        MessageView(message: message)
            .opacity(opacity)
            .offset(y: offset)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) {
                    opacity = 1.0
                    offset = 0
                }
            }
    }
}

typealias DelayedSequentialFadeInMessageView = SequentialFadeInMessageView

struct SequentialFadeInMessageView: View {
    let message: Message
    let initialDelay: Double
    @State private var blocks: [String] = []
    
    init(message: Message, initialDelay: Double = 0) {
        self.message = message
        self.initialDelay = initialDelay
    }
    
    var body: some View {
        if message.role == .assistant {
            let (thinking, afterThink) = processThinkingContent(message.content)
            VStack(alignment: .leading, spacing: 16) {
                if let thinking {
                    thinkingSection(thinking)
                }
                
                if let afterThink {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                            FadingMarkdownBlock(text: block, delay: Double(index) * 0.2, initialDelay: initialDelay)
                        }
                    }
                    .onAppear {
                        // Split content into blocks by paragraphs (double newline)
                        let paragraphs = afterThink.components(separatedBy: "\n\n")
                        blocks = paragraphs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    }
                }
            }
            .padding(.trailing, 48)
        } else {
            MessageView(message: message)
        }
    }
    
    private func processThinkingContent(_ content: String) -> (String?, String?) {
        guard let startRange = content.range(of: "<think>") else {
            return (nil, content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let endRange = content.range(of: "</think>") else {
            let thinking = String(content[startRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (thinking, nil)
        }
        let thinking = String(content[startRange.upperBound ..< endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let afterThink = String(content[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (thinking, afterThink.isEmpty ? nil : afterThink)
    }
    

    private func thinkingSection(_ thinking: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .fontWeight(.medium)
                Text("thought for 0s")
                    .italic()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}

struct LatestActivityView: View {
    let activities: [AgentActivity]
    
    var body: some View {
        if let latestActivity = activities.last {
            AnimatedActivityView(activity: latestActivity)
                .id(latestActivity.id)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }
}

extension TimeInterval {
    var formatted: String {
        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        } else {
            return "\(seconds)s"
        }
    }
}

struct MessageView: View {
    @Environment(LLMEvaluator.self) var llm
    @State private var collapsed = true
    let message: Message

    var isThinking: Bool {
        !message.content.contains("</think>")
    }

    func processThinkingContent(_ content: String) -> (String?, String?) {
        guard let startRange = content.range(of: "<think>") else {
            // No <think> tag, return entire content as the second part
            return (nil, content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let endRange = content.range(of: "</think>") else {
            // No </think> tag, return content after <think> without the tag
            let thinking = String(content[startRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (thinking, nil)
        }

        let thinking = String(content[startRange.upperBound ..< endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let afterThink = String(content[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        return (thinking, afterThink.isEmpty ? nil : afterThink)
    }

    var time: String {
        if isThinking, llm.running, let elapsedTime = llm.elapsedTime {
            if isThinking {
                return "(\(elapsedTime.formatted))"
            }
            if let thinkingTime = llm.thinkingTime {
                return thinkingTime.formatted
            }
        } else if let generatingTime = message.generatingTime {
            return "\(generatingTime.formatted)"
        }

        return "0s"
    }

    var thinkingLabel: some View {
        HStack {
            Button {
                collapsed.toggle()
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 12))
                    .fontWeight(.medium)
            }

            Text("\(isThinking ? "thinking..." : "thought for") \(time)")
                .italic()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    var webSearchBadge: some View {
        Text("web search")
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(
                Capsule()
                    .fill(Color.blue)
            )
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer() }

            if message.role == .assistant {
                let (thinking, afterThink) = processThinkingContent(message.content)
                VStack(alignment: .leading, spacing: 16) {
                    if message.usedWebSearch == true {
                        webSearchBadge
                    }
                    if let thinking {
                        VStack(alignment: .leading, spacing: 12) {
                            thinkingLabel
                            if !collapsed {
                                if !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack(spacing: 12) {
                                        Capsule()
                                            .frame(width: 2)
                                            .padding(.vertical, 1)
                                            .foregroundStyle(.fill)
                                        Markdown(thinking)
                                            .textSelection(.enabled)
                                            .markdownTextStyle {
                                                ForegroundColor(.secondary)
                                            }
                                    }
                                    .padding(.leading, 5)
                                }
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture {
                            collapsed.toggle()
                            if isThinking {
                                llm.collapsed = collapsed
                            }
                        }
                    }

                    if let afterThink {
                        Markdown(afterThink)
                            .textSelection(.enabled)
                    }
                }
                .padding(.trailing, 48)
            } else {
                Markdown(message.content)
                    .textSelection(.enabled)
                #if os(iOS) || os(visionOS)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                #else
                    .padding(.horizontal, 16 * 2 / 3)
                    .padding(.vertical, 8)
                #endif
                    .background(platformBackgroundColor)
                #if os(iOS) || os(visionOS)
                    .mask(RoundedRectangle(cornerRadius: 24))
                #elseif os(macOS)
                    .mask(RoundedRectangle(cornerRadius: 16))
                #endif
                    .padding(.leading, 48)
            }

            if message.role == .assistant { Spacer() }
        }
        .onAppear {
            if llm.running {
                collapsed = false
            }
        }
        .onChange(of: llm.elapsedTime) {
            if isThinking {
                llm.thinkingTime = llm.elapsedTime
            }
        }
        .onChange(of: isThinking) {
            if llm.running {
                llm.isThinking = isThinking
            }
        }
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
}

struct ConversationView: View {
    @Environment(LLMEvaluator.self) var llm
    @EnvironmentObject var appManager: AppManager
    let thread: Thread
    let generatingThreadID: UUID?

    @State private var scrollID: String?
    @State private var scrollInterrupted = false
    @State private var lastScrollTime: Date = .distantPast
    @State private var lastCompletedMessageID: UUID?

    var body: some View {
        ScrollViewReader { scrollView in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(thread.sortedMessages) { message in
                        Group {
                            if message.role == .assistant && message.id == lastCompletedMessageID {
                                // Apply sequential fade-in animation to the most recently completed message
                                SequentialFadeInMessageView(message: message)
                            } else {
                                MessageView(message: message)
                            }
                        }
                        .padding()
                        .id(message.id.uuidString)
                    }

                    if llm.running && thread.id == generatingThreadID {
                        VStack(alignment: .leading, spacing: 12) {
                            // Show output based on whether we're finalizing
                            if llm.isFinalizingAnswer {
                                // Hide streaming, show fade-in animation with 0.5s initial delay
                                if !llm.output.isEmpty {
                                    DelayedSequentialFadeInMessageView(
                                        message: Message(role: .assistant, content: llm.output),
                                        initialDelay: 0.5
                                    )
                                    .padding(.horizontal)
                                }
                            } else {
                                // Show normal streaming output with fade-in
                                if !llm.output.isEmpty {
                                    FadeInMessageView(
                                        message: Message(role: .assistant, content: llm.output + " 🌕")
                                    )
                                    .padding(.horizontal)
                                } else {
                                    // Show thinking indicator while waiting for initial response
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(.secondary)
                                            .frame(width: 6, height: 6)
                                        Text("thinking...")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .italic()
                                    }
                                    .padding(.horizontal)
                                    .opacity(0.7)
                                }
                            }
                            
                            // Show only the latest activity below the output with smooth transitions
                            if !llm.agentActivities.isEmpty {
                                LatestActivityView(activities: llm.agentActivities)
                            }
                        }
                        .padding(.vertical)
                        .id("output")
                        .onAppear {
                            print("output appeared")
                            scrollInterrupted = false // reset interruption when a new output begins
                        }
                    }

                    Rectangle()
                        .fill(.clear)
                        .frame(height: 1)
                        .id("bottom")
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollID, anchor: .bottom)
            .onChange(of: llm.output) { _, _ in
                // Don't auto-scroll when finalizing answer (user should see top first)
                if !llm.isFinalizingAnswer {
                    // Throttle scroll updates to every 100ms
                    let now = Date()
                    if !scrollInterrupted && now.timeIntervalSince(lastScrollTime) > 0.1 {
                        lastScrollTime = now
                        scrollView.scrollTo("bottom")
                    }
                }

                if !llm.isThinking {
                    appManager.playHaptic()
                }
            }

            .onChange(of: scrollID) { _, _ in
                // interrupt auto scroll to bottom if user scrolls away
                if llm.running {
                    scrollInterrupted = true
                }
            }
            .onChange(of: llm.isFinalizingAnswer) { wasFinalizing, isFinalizingNow in
                // When final answer starts, scroll to top of output so user sees first block
                if !wasFinalizing && isFinalizingNow {
                    // Small delay to ensure content is rendered
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollView.scrollTo("output", anchor: .top)
                        }
                    }
                }
            }
            .onChange(of: llm.running) { wasRunning, isRunning in
                // Detect when generation completes
                if wasRunning && !isRunning {
                    // Generation just finished - mark the last message for fade-in animation
                    if let lastMessage = thread.sortedMessages.last, lastMessage.role == .assistant {
                        lastCompletedMessageID = lastMessage.id
                    }
                }
            }
        }
        .defaultScrollAnchor(llm.isFinalizingAnswer ? nil : .bottom)
        #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

#Preview {
    ConversationView(thread: Thread(), generatingThreadID: nil)
        .environment(LLMEvaluator())
        .environmentObject(AppManager())
}
