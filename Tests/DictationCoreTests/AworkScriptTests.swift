@testable import DictationCore
import Foundation
import Testing

struct AworkScriptTests {
    @Test func requests() {
        #expect(AworkScript.request(method: "GET", path: "users/me") == #"return await awork.read("/users/me", {});"#)
        #expect(AworkScript.request(method: "POST", path: "tasks/abc/setassignees", body: ["u1"])
                == #"return await awork.post("/tasks/abc/setassignees", ["u1"], {});"#)
        #expect(AworkScript.request(method: "DELETE", path: "/timeentries/x") == #"return await awork.delete("/timeentries/x", {});"#)
        #expect(AworkScript.paged(path: "projects/p1/projecttasks").contains(#"awork.read("/projects/p1/projecttasks", Object.assign({}, { page, pageSize: 500 }))"#))
    }

    @Test func payloadIsTheStoredResult() throws {
        // As the awork MCP answered on 2026-10-21: the notice of the stored result, then the data.
        let notice = #"{"success":true,"result":"{\"summary\":{\"total\":1},\"data\":\"[[\\u0022a\\u0022]]... (truncated)\",\"dataTruncated\":true,\"dataRef\":\"64b6\"}","errorMessage":null}"#
        let data = #"{"success":true,"result":"[[\"id1\",\"[NW] Interne Aufgaben\"]]","traceId":"x"}"#
        let payload = try AworkScript.payload(from: [notice, data]) as? [[String]]
        #expect(payload == [["id1", "[NW] Interne Aufgaben"]])
        #expect(throws: AworkScript.Failure.self) { try AworkScript.payload(from: [notice]) }
        #expect(throws: AworkScript.Failure.self) { try AworkScript.payload(from: [#"{"success":false,"errorMessage":"403"}"#]) }
    }
}
