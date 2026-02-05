import Foundation
import Testing

@testable import fullmoon

struct TitleParsingTests {
    @Test
    func jsonResponseParsesTitle() {
        let json = """
        {"choices":[{"message":{"content":"My Title"}}]}
        """
        let data = Data(json.utf8)
        #expect(OpenAIClient.extractChatText(from: data) == "My Title")
    }

    @Test
    func sseResponseParsesTitle() {
        let sse = """
        data: {"choices":[{"delta":{"content":"My "}}]}

        data: {"choices":[{"delta":{"content":"Title"}}]}

        data: [DONE]
        """
        let data = Data(sse.utf8)
        #expect(OpenAIClient.extractChatText(from: data) == "My Title")
    }

    @Test
    func fallbackParsesIfProviderReturnsUnexpectedShape() {
        let json = """
        {"choices":[{"message":{"content":"Fallback Title"}}]}
        """
        let data = Data(json.utf8)
        #expect(OpenAIClient.extractChatText(from: data) == "Fallback Title")
    }

    @Test
    func extractJSONTitleParsesValidTitle() {
        let json = """
        {"choices":[{"message":{"content":"{\\"title\\": \\"Best Football Players\\"}"}}]}
        """
        let data = Data(json.utf8)
        let title = OpenAIClient.extractJSONTitle(from: data)
        #expect(title == "Best Football Players")
    }

    @Test
    func extractJSONTitleRejectsReasoningArtifact() {
        // This simulates the glm-4.7 model putting reasoning in the title field
        let json = """
        {"choices":[{"message":{"content":"{\\"title\\": \\"2.  **Identify the constraints:\\"}"}}]}
        """
        let data = Data(json.utf8)
        let title = OpenAIClient.extractJSONTitle(from: data)
        #expect(title == nil)
    }

    @Test
    func extractJSONTitleRejectsNumberedListPrefix() {
        let json = """
        {"choices":[{"message":{"content":"{\\"title\\": \\"1. Analyze the conversation\\"}"}}]}
        """
        let data = Data(json.utf8)
        let title = OpenAIClient.extractJSONTitle(from: data)
        #expect(title == nil)
    }

    @Test
    func extractJSONTitleRejectsMarkdownFormatting() {
        let json = """
        {"choices":[{"message":{"content":"{\\"title\\": \\"**Bold Title**\\"}"}}]}
        """
        let data = Data(json.utf8)
        let title = OpenAIClient.extractJSONTitle(from: data)
        #expect(title == nil)
    }

    @Test
    func extractJSONTitleRejectsTooLongText() {
        let longText = String(repeating: "word ", count: 20)
        let json = """
        {"choices":[{"message":{"content":"{\\"title\\": \\"\(longText)\\"}"}}]}
        """
        let data = Data(json.utf8)
        let title = OpenAIClient.extractJSONTitle(from: data)
        #expect(title == nil)
    }

    @Test
    func extractJSONTitleRejectsAnalyzePrefix() {
        let json = """
        {"choices":[{"message":{"content":"{\\"title\\": \\"Analyze the conversation topic\\"}"}}]}
        """
        let data = Data(json.utf8)
        let title = OpenAIClient.extractJSONTitle(from: data)
        #expect(title == nil)
    }

    @Test
    func extractJSONTitleRejectsIdentifyPrefix() {
        let json = """
        {"choices":[{"message":{"content":"{\\"title\\": \\"Identify the constraints\\"}"}}]}
        """
        let data = Data(json.utf8)
        let title = OpenAIClient.extractJSONTitle(from: data)
        #expect(title == nil)
    }
}
