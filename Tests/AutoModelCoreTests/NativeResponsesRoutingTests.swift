import XCTest
@testable import AutoModelCore

final class NativeResponsesRoutingTests: XCTestCase {
    func testLiteToolsRequireNativeTransportAndRemainVisibleToRouting() throws {
        let payload: [String: Any] = ["model": "terra", "input": [
            ["type": "additional_tools", "tools": [["type": "namespace", "name": "functions", "tools": [["type": "custom", "name": "exec"]]]]],
            ["role": "user", "content": "read the repository"]
        ]]
        XCTAssertTrue(NativeResponsesRouting.isRequired(payload))
        let routing = NativeResponsesRouting.routingPayload(payload)
        XCTAssertTrue(RequestFeatureExtractor.extract(from: routing).requiresTools)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: NativeResponsesRouting.wirePayload(payload), options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    }

    func testDesktopContextRepairPreservesCustomCallsAndValidNamespaces() throws {
        let items: [[String: Any]] = [
            ["type": "function_call_output", "name": "selection", "output": [["text": "selected"]]],
            ["type": "custom_tool_call", "namespace": "functions", "name": "exec", "call_id": "custom1", "input": "await tools.exec_command({cmd:'pwd'})"],
            ["type": "custom_tool_call_output", "call_id": "custom1", "output": "/workspace"],
            ["type": "function_call_output", "call_id": "valid_earlier_call", "output": "valid"]
        ]
        let repaired = try XCTUnwrap(NativeResponsesRouting.wirePayload(["input": items])["input"] as? [[String: Any]])
        XCTAssertEqual(repaired.first?["role"] as? String, "user")
        XCTAssertTrue(String(data: try JSONSerialization.data(withJSONObject: repaired[0]), encoding: .utf8)!.contains("selected"))
        for i in 1..<items.count {
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: repaired[i], options: [.sortedKeys]),
                           try JSONSerialization.data(withJSONObject: items[i], options: [.sortedKeys]))
        }
    }

    func testPlainFunctionCallsKeepExistingChatCompatibility() {
        XCTAssertFalse(NativeResponsesRouting.isRequired(["tools": [["type": "function", "name": "lookup"]], "input": "Hi"]))
        XCTAssertTrue(NativeResponsesRouting.isRequired(["tools": [["type": "custom", "name": "exec"]], "input": "Hi"]))
        XCTAssertTrue(NativeResponsesRouting.isRequired(["input": [["type": "function_call", "namespace": "functions", "name": "exec"]]]))
    }
}
