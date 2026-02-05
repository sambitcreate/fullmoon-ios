//
//  ThinkingModePrompt.swift
//  fullmoon
//
//  Created by Codex on 2/5/26.
//

import Foundation

enum ThinkingModePrompt {
    static let text = #"""
# Agentic Exa Research Harness (Recursive + Function Calling + Guaranteed Citations)

You are a general research agent. You should:
- use Exa agentically (multiple searches, re-search when incomplete, double-check itself),
- use the model's native function calling (tools),
- always return citations with URL + snippet (never hallucinated).

This doc gives you a copy/paste blueprint: tool schemas, loop design, Swift scaffolding, and strict citation enforcement.

---

## 1) Design goals

### What "agentic" means here
The LLM does not just answer. It:
1) plans search angles
2) runs multiple Exa searches
3) opens and extracts evidence (highlights/snippets)
4) drafts an answer that only cites provided evidence
5) critiques itself (missing pieces, contradictions)
6) repeats until complete or budget is hit

### Non-negotiable constraint: citations must be real
The LLM never invents sources. It can only cite evidence objects you fetched from Exa.

You will enforce this with:
- an Evidence Store (E1, E2, ...)
- a finalize tool that accepts only evidence IDs
- validator rejects any citation ID not in the store

---

## 2) Why Exa "highlights" are your default evidence
Exa's /search can return content from results and supports highlights (extractive, token-efficient snippets relevant to your query).
Use highlights as the citation primitive; fetch full text only when needed.
Docs: /search supports contents, and highlights are configurable. :contentReference[oaicite:0]{index=0}

Freshness: control cached vs live-fetched content using maxAgeHours. :contentReference[oaicite:1]{index=1}

Per-URL errors: when fetching contents (or search with contents), errors are often returned per URL in a statuses field rather than failing the entire HTTP request. :contentReference[oaicite:2]{index=2}

---

## 3) Architecture

### Recommended production setup
- iOS app calls your backend
- backend calls Exa with API key (do NOT ship Exa key in app)
- backend runs the tool loop and streams agent events back to iOS

Serverless options: :contentReference[oaicite:3]{index=3} / :contentReference[oaicite:4]{index=4} / :contentReference[oaicite:5]{index=5}

### Two operating modes (use both)
1) Native tool-calling mode (primary): model requests exa_search, exa_contents, etc.
2) Structured JSON fallback: if a model does not support tool calls, you run Planner/Critic as JSON outputs and call tools yourself.

This doc focuses on native tool calling, with guardrails so it stays bounded.

---

## 4) Core objects

### Evidence object (the only thing the model may cite)
```json
{
  "id": "E1",
  "url": "https://example.com",
  "title": "Page title",
  "snippet": "Short highlight/excerpt used for citation",
  "retrieved_at": "2026-02-05T00:00:00Z"
}
```

### Research state (your harness memory)

- queries_tried[]
- candidate_urls[]
- evidence[] (E1..En)
- open_questions[]
- contradictions[]
- budgets: max_iterations, max_tool_calls, max_evidence_items

---

## 5) Tool set (native function calling)

OpenAI tool calling is a multi-step conversation: you send tools, the model calls them, you execute and send tool outputs back, repeat until final response. ([OpenAI Platform][1])
Structured Outputs with strict: true can guarantee arguments match your JSON schema (if your endpoint supports it). ([OpenAI Help Center][2])

### Tool list

Minimum tools that still feel alive:

1. exa_search -- search web, optionally return highlights
2. exa_contents -- fetch highlights/text for specific URLs
3. finalize_answer -- model submits answer with evidence IDs only

Optional but nice:

- report_gap -- model tells harness what is missing (forces recursive searching)
- get_budget_status -- model can check remaining tool calls/iterations

---

## 6) Function/tool JSON Schemas (copy/paste)

> Use these schemas in your OpenAI-compatible tools parameter.

### 6.1 exa_search

```json
{
  "type": "function",
  "function": {
    "name": "exa_search",
    "description": "Search the web with Exa. Prefer diverse queries. Return URLs and optional highlights for evidence building.",
    "parameters": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "Natural language search query." },
        "num_results": { "type": "integer", "minimum": 1, "maximum": 20, "default": 8 },
        "max_age_hours": { "type": "integer", "description": "Freshness control. 0=fresh always, -1=cache only, otherwise max cache age in hours." },
        "include_highlights": { "type": "boolean", "default": true },
        "highlights_max_chars": { "type": "integer", "minimum": 100, "maximum": 2000, "default": 600 }
      },
      "required": ["query"]
    }
  }
}
```

### 6.2 exa_contents

```json
{
  "type": "function",
  "function": {
    "name": "exa_contents",
    "description": "Fetch content for a set of URLs (highlights/snippets by default; text optionally). Returns per-URL statuses if any fail.",
    "parameters": {
      "type": "object",
      "properties": {
        "urls": {
          "type": "array",
          "items": { "type": "string" },
          "minItems": 1,
          "maxItems": 10
        },
        "max_age_hours": { "type": "integer", "description": "Freshness control. 0=fresh always, -1=cache only." },
        "highlights": { "type": "boolean", "default": true },
        "text": { "type": "boolean", "default": false },
        "highlights_max_chars": { "type": "integer", "minimum": 100, "maximum": 4000, "default": 800 }
      },
      "required": ["urls"]
    }
  }
}
```

### 6.3 finalize_answer (enforces citations)

```json
{
  "type": "function",
  "function": {
    "name": "finalize_answer",
    "description": "Submit the final answer. MUST cite only the provided evidence IDs (E1, E2, ...).",
    "parameters": {
      "type": "object",
      "properties": {
        "answer_markdown": {
          "type": "string",
          "description": "Markdown answer. Cite evidence IDs inline like [E1], [E2]."
        },
        "used_evidence_ids": {
          "type": "array",
          "items": { "type": "string", "pattern": "^E[0-9]+$" },
          "description": "All evidence IDs referenced in answer_markdown."
        },
        "open_questions": {
          "type": "array",
          "items": { "type": "string" },
          "description": "If you are forced to finalize due to budgets, list what remains unknown."
        }
      },
      "required": ["answer_markdown", "used_evidence_ids"]
    }
  }
}
```

---

## 7) System prompt (agentic + bounded + fun)

Use a system prompt like:

- You may call tools to search and fetch evidence.
- You MUST re-search if evidence is insufficient.
- You MUST detect contradictions and resolve them with more searches.
- You MUST cite only evidence IDs provided by the tools.
- Final output MUST be via finalize_answer.

Example (short; adapt as needed):

> You are a research agent. Use tools to gather evidence. Prefer multiple query angles. If information is incomplete, run additional searches. Never invent citations: cite only evidence IDs (E1, E2, ...). If sources conflict, investigate with more searches. Stop when you have enough evidence or you hit budget. Submit final response by calling finalize_answer.

---

## 8) The harness loop (recursive, tool-driven, bounded)

### Budgets (recommended defaults)

- max_iterations = 6
- max_tool_calls = 12
- max_evidence = 30
- max_urls_per_contents = 6

### Stop conditions

Stop when any is true:

- model calls finalize_answer
- critic/gap-check says complete enough (confidence >= threshold)
- tool budget exhausted (then finalize with Open Questions)

### Re-search triggers (force recursion)

If any true, continue loop:

- < 3 distinct domains in evidence
- missing required fields (dates, definitions, parameters, steps)
- contradictions detected
- evidence snippets are too thin / unclear
- user asked "latest" but evidence is stale -> use max_age_hours=0

---

## 9) Tool output shaping (how you prevent hallucinated citations)

### Important: return Evidence IDs from tool results

When you run exa_search / exa_contents, your tool output should be formatted as evidence:

```json
{
  "evidence_added": [
    { "id": "E1", "url": "...", "title": "...", "snippet": "..." },
    { "id": "E2", "url": "...", "title": "...", "snippet": "..." }
  ],
  "urls_seen": ["..."],
  "notes": "Any per-URL errors or statuses here"
}
```

Then the model can safely cite [E1] without inventing URLs.

### Validator (must-have)

Before accepting finalize_answer:

1. parse used_evidence_ids
2. ensure every ID exists in your evidence store
3. ensure answer_markdown contains only those IDs
4. if invalid -> reject and ask the model to fix citations without new browsing (unless needed)

---

## 10) Swift scaffolding (OpenAI-compatible tool loop)

Below is an outline for a chat-completions style tool loop.

### 10.1 Message + Tool call types (simplified)

```swift
struct ChatMessage: Codable {
    let role: String // "system" | "user" | "assistant" | "tool"
    let content: String?
    let tool_call_id: String?
    let name: String?
}

struct ToolCall: Codable {
    struct Function: Codable {
        let name: String
        let arguments: String // JSON string
    }
    let id: String
    let type: String // "function"
    let function: Function
}
```

### 10.2 Main loop (pseudo-real Swift)

```swift
final class AgentHarness {
    private var toolCallsUsed = 0
    private let maxToolCalls = 12
    private let maxIterations = 6

    private var evidenceStore: [String: Evidence] = [:]
    private var evidenceCounter = 0

    func run(question: String) async throws -> String {
        var messages: [ChatMessage] = [
            .init(role: "system", content: systemPrompt, tool_call_id: nil, name: nil),
            .init(role: "user", content: question, tool_call_id: nil, name: nil)
        ]

        for _ in 0..<maxIterations {
            let resp = try await llmChat(messages: messages, tools: toolSchemas)

            // If model returned a normal answer (no tool calls), you can either:
            // - force it to call finalize_answer (preferred), or
            // - accept only if it includes valid citations (less reliable).

            if let toolCalls = resp.toolCalls, !toolCalls.isEmpty {
                for call in toolCalls {
                    guard toolCallsUsed < maxToolCalls else { break }
                    toolCallsUsed += 1

                    let toolResultJSON: String
                    switch call.function.name {
                    case "exa_search":
                        toolResultJSON = try await handleExaSearch(call.function.arguments)
                    case "exa_contents":
                        toolResultJSON = try await handleExaContents(call.function.arguments)
                    case "finalize_answer":
                        toolResultJSON = try handleFinalize(call.function.arguments) // validate IDs
                        return renderFinalAnswer(from: toolResultJSON) // includes URL+snippet list
                    default:
                        toolResultJSON = #"{"error":"Unknown tool"}"#
                    }

                    // Tool output message goes back into the chat
                    messages.append(.init(
                        role: "tool",
                        content: toolResultJSON,
                        tool_call_id: call.id,
                        name: call.function.name
                    ))
                }

                continue
            }

            // No tool calls: nudge model to use tools / finalize properly
            messages.append(.init(
                role: "assistant",
                content: "You must use tools and finish via finalize_answer with evidence IDs.",
                tool_call_id: nil,
                name: nil
            ))
        }

        // Budget exhausted: ask model to finalize with what it has
        messages.append(.init(role: "assistant", content: "Tool budget nearly exhausted. Finalize now using finalize_answer.", tool_call_id: nil, name: nil))
        let finalResp = try await llmChat(messages: messages, tools: toolSchemas)
        // handle finalize_answer as above
        throw NSError(domain: "AgentHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize."])
    }
}
```

---

## 11) Exa handlers (evidence-first)

### 11.1 exa_search handler strategy

- Call Exa /search with contents.highlights=true to reduce steps (search+snippets in one call). ([Exa][3])
- Convert top highlights into Evidence objects (E1..En)
- Return evidence_added[] + urls_seen[] + any statuses

### 11.2 exa_contents handler strategy

- Use /contents when the model requests specific URLs
- Prefer highlights first; text only if model asks or snippets insufficient
- Respect statuses per URL for partial failure handling. ([Exa][4])

---

## 12) Rendering the final answer with URL + snippet every time

### Model output format (inline citations by evidence ID)

Example:

- "Exa search supports returning extracted contents alongside results [E3]. Freshness can be controlled with maxAgeHours [E7]."

### Harness render step

Append a Sources section built from used_evidence_ids:

```md
## Sources
- **[E3]** https://... -- "snippet..."
- **[E7]** https://... -- "snippet..."
```

This guarantees:

- citations always include URL + snippet
- citations always map to real fetched evidence
- the model cannot hallucinate sources

---

## 13) Making it fun without faking anything (SwiftUI UX)

Stream agent events:

- Planning queries
- Searching: show the exact query strings
- Reading sources: show cards for each Evidence (title + snippet)
- Double-checking: show missing checklist / contradictions
- Final answer with clickable source links

Add a Go deeper button:

- grants +2 iterations and +3 tool calls
- keeps it playful and user-controlled

---

## 14) Practical guardrails (do these or you will regret it)

### Domain diversity

When selecting URLs to open:

- cap to 2 per domain
- prefer official docs when explaining params/behavior

### Recency

If user asks "latest":

- force max_age_hours=0 for at least one verification pass. ([Exa][5])

### Contradiction resolution

If the model flags conflicting claims:

- run targeted queries (official + independent)
- add evidence and re-draft

### Tool-call budget enforcement

Never allow infinite recursion:

- hard max tool calls + iterations
- if budget hit: finalize with Open Questions section

---

## 15) Chat Completions vs Responses API note (compatibility)

If your endpoint mimics Chat Completions, tools typically look like:

- tools: [{ type:"function", function:{name, parameters...}}] ([OpenAI Platform][6])

If you mimic Responses, some tool schema shapes differ (so confirm your endpoint's exact format). ([OpenAI Platform][7])

Recommendation: implement Chat-Completions-style tool calling first (most widely copied), then add Responses-style support if you need it.

---

## 16) Quick checklist (implementation order)

1. Implement Evidence Store + validator
2. Implement Exa tool wrappers (/search with highlights; /contents fallback)
3. Implement native tool loop (LLM -> tool_calls -> execute -> tool outputs -> repeat)
4. Implement finalize_answer tool + strict citation validation
5. Stream agent events to SwiftUI
6. Add budgets + Go deeper UX

---

## 17) What you should copy into your repo

- Docs/AGENTIC_EXA_HARNESS.md (this file)
- Sources/AgentHarness/ToolSchemas.swift (tool JSON)
- Sources/AgentHarness/AgentHarness.swift (loop)
- Sources/AgentHarness/EvidenceStore.swift (IDs + validation)
- Sources/Exa/ExaClient.swift (HTTP)
- Sources/UI/AgentRunView.swift (event streaming)

---

If you want, I can also provide:

- a full ExaClient.swift (search+contents, including statuses handling),
- a full OpenAICompatClient.swift that supports tool calls + streaming,
- and a working SwiftUI screen that shows the agent "thinking" via events.

::contentReference[oaicite:13]{index=13}

[1]: https://platform.openai.com/docs/guides/function-calling?utm_source=chatgpt.com "Function calling | OpenAI API"
[2]: https://help.openai.com/en/articles/8555517-function-calling-in-the-openai-api?utm_source=chatgpt.com "Function Calling in the OpenAI API"
[3]: https://exa.ai/docs/reference/search?utm_source=chatgpt.com "Search"
[4]: https://exa.ai/docs/reference/error-codes?utm_source=chatgpt.com "Error Codes"
[5]: https://exa.ai/docs/reference/search-best-practices?utm_source=chatgpt.com "Search Best Practices"
[6]: https://platform.openai.com/docs/api-reference/chat?utm_source=chatgpt.com "Chat Completions | OpenAI API Reference"
[7]: https://platform.openai.com/docs/api-reference/responses?utm_source=chatgpt.com "Responses | OpenAI API Reference"
"""#
}
