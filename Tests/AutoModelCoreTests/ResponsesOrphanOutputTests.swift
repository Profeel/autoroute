import XCTest
@testable import AutoModelCore

final class ResponsesOrphanOutputTests: XCTestCase {
    func testOrphanOutputsPreserveContentWithoutInventingCallIDs() throws {
        let payload: [String: Any] = [
            "input": [
                ["role": "user", "content": "question"],
                ["type": "function_call_output", "name": "desktop_page", "output": "page context"],
                ["type": "function_call_output", "call_id": "", "name": "selection", "output": "selected text"],
                ["type": "function_call", "call_id": "call_valid", "name": "lookup", "arguments": "{}"],
                ["type": "function_call_output", "call_id": "call_valid", "output": "valid result"]
            ]
        ]
        guard case .success(let chat) = ProtocolAdapters.responsesToChatRequest(payload),
              let messages = chat["messages"] as? [[String: Any]] else {
            return XCTFail("Responses conversion failed")
        }
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "user", "user", "assistant", "tool"])
        XCTAssertTrue((messages[1]["content"] as? String ?? "").contains("page context"))
        XCTAssertTrue((messages[1]["content"] as? String ?? "").contains("desktop_page"))
        XCTAssertTrue((messages[2]["content"] as? String ?? "").contains("selected text"))
        XCTAssertEqual(messages[4]["tool_call_id"] as? String, "call_valid")
        let responses = ProtocolAdapters.chatToResponsesRequest(chat, modelID: "test", forceStream: false)
        let input = try XCTUnwrap(responses["input"] as? [[String: Any]])
        let outputs = input.filter { ($0["type"] as? String) == "function_call_output" }
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?["call_id"] as? String, "call_valid")
    }
}
