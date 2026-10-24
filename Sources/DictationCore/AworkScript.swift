import Foundation

/// awork API calls as JavaScript for the awork MCP server, for using awork without the app's
/// own API client. Reads run in `awork_query`, writes in `awork_action`; both take relative
/// routes and return the response body. Results above a few kilobytes come back cut, so every
/// call stores its result (`forceDataRef`) and `continue_reading` returns it whole.
public enum AworkScript {
    public enum Failure: Error, CustomStringConvertible {
        case noResult
        case failed(String)

        public var description: String {
            switch self {
            case .noResult: return "The awork MCP returned no result."
            case .failed(let message): return "The awork MCP failed: \(message)"
            }
        }
    }

    /// One API call. `path` is relative ("users/me", "tasks/ID/setassignees"), a query after "?"
    /// becomes the query object.
    public static func request(method: String, path: String, body: Any? = nil) -> String {
        let (route, query) = split(path)
        let queryText = literal(query)
        switch method.uppercased() {
        case "GET": return "return await awork.read(\(literal(route)), \(queryText));"
        case "DELETE": return "return await awork.delete(\(literal(route)), \(queryText));"
        default:
            let helper = method.uppercased() == "PUT" ? "put" : "post"
            return "return await awork.\(helper)(\(literal(route)), \(literal(body)), \(queryText));"
        }
    }

    /// The fields the app reads from list items; everything else stays on the server, because a
    /// whole list of full objects is larger than one stored result can return.
    public static let listFields = ["id", "name", "closedOn", "projectStatus.type", "company.name", "projectKey", "key",
                                    "parentId", "taskStatus.type", "taskIdentifier", "firstName", "lastName"]

    /// Every page of a list in one script, 500 per page, as the direct client reads it, cut to
    /// `listFields`.
    public static func paged(path: String) -> String {
        let (route, query) = split(path)
        return """
        const fields = \(literal(listFields));
        const pick = (item) => {
          const out = {};
          for (const field of fields) {
            const [head, tail] = field.split('.');
            const value = item[head];
            if (value === undefined || value === null) continue;
            if (tail) { out[head] = Object.assign(out[head] || {}, { [tail]: value[tail] }); } else { out[head] = value; }
          }
          return out;
        };
        const all = [];
        for (let page = 1; page <= 25; page++) {
          const items = await awork.read(\(literal(route)), Object.assign(\(literal(query)), { page, pageSize: 500 }));
          all.push(...items.map(pick));
          if (items.length < 500) break;
        }
        return all;
        """
    }

    /// The instruction for Claude Code: run the script unchanged, then read its stored result.
    public static func prompt(script: String, write: Bool, intent: String) -> String {
        """
        Call the tool mcp__awork__\(write ? "awork_action" : "awork_query") exactly once with intent "\(intent)", forceDataRef true and exactly this code, unchanged:

        \(script)

        Then call mcp__awork__continue_reading with the dataRef it returned and length 160000. Do nothing else and answer only "done".
        """
    }

    /// The call's result from the tool results of the run: the last one that holds data, which
    /// is `continue_reading`'s. An error of either tool is thrown.
    public static func payload(from toolResults: [String]) throws -> Any? {
        for text in toolResults.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            if (object["success"] as? Bool) == false {
                throw Failure.failed(object["errorMessage"] as? String ?? text.prefix(200).description)
            }
            guard let result = object["result"] as? String else { continue }
            // The stored-result notice of the first call is not the data.
            if let notice = try? JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed]) as? [String: Any],
               notice["dataRef"] != nil, notice["summary"] != nil || notice["preview"] != nil || notice["dataTruncated"] != nil {
                continue
            }
            let value = try? JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed])
            if let chunk = value as? [String: Any], chunk["dataChunk"] != nil, chunk["nextOffset"] != nil {
                throw Failure.failed("the result is larger than one read (160 KB)")
            }
            return value
        }
        throw Failure.noResult
    }

    static func split(_ path: String) -> (route: String, query: [String: String]) {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let route = "/" + (parts.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if let key = kv.first, !key.isEmpty { query[key] = kv.count > 1 ? kv[1] : "" }
            }
        }
        return (route, query)
    }

    /// A JSON literal, which is also valid JavaScript.
    static func literal(_ value: Any?) -> String {
        guard let value else { return "undefined" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else {
            return "undefined"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
