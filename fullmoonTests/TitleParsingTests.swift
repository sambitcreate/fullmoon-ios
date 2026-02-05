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
}
