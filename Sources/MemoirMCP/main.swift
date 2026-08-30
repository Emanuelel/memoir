import Foundation
import MemoirKit

// Memoir's MCP server.
//
// Newline-delimited JSON-RPC 2.0 over stdio, protocol 2025-06-18. Opens Memoir's
// database READ-ONLY and exposes twelve tools so an agent you already use can consult
// your work memory.
//
// Hard rule: stdout carries JSON-RPC frames and nothing else. Every diagnostic goes
// to stderr, because a single stray byte on stdout corrupts the stream and the client
// silently drops the connection.

let databaseURL = resolveDatabaseURL()
let memory = MemoirMemory(path: databaseURL)
let handler = ToolHandler(
    memory: memory,
    proposalsURL: ProposalStore.url(alongsideDatabase: databaseURL)
)

if CommandLine.arguments.contains("--selftest") {
    await SelfTest.run(memory: memory, handler: handler)
    exit(0)
}

MCPLog.info("memoir-mcp ready; db=\(databaseURL.path)")

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { continue }

    let request: RPCRequest
    do {
        request = try JSONRPC.decode(line: trimmed)
    } catch let error as RPCError {
        emit(JSONRPC.failure(id: nil, error: error))
        continue
    } catch {
        emit(JSONRPC.failure(id: nil, error: RPCError(.parseError, "\(error)")))
        continue
    }

    guard let response = await handle(request, handler: handler) else { continue }
    emit(response)
}

MCPLog.info("stdin closed, exiting")

// MARK: - Dispatch

/// The revisions this server can speak, newest first.
///
/// `structuredContent` needs 2025-06-18; everything else here works on either.
///
/// A static on a type rather than a plain global, because this is `main.swift`: globals
/// there are top-level code and initialise in execution order, so one declared below the
/// run loop is read before it exists and the server dies with a segfault mid-handshake.
/// Type members are lazy and have no such ordering.
enum MCPProtocol {
    static let supported = ["2025-06-18", "2024-11-05"]
}

/// The revision to answer `initialize` with: the client's own if we speak it, ours otherwise.
///
/// A client that gets back a version it did not offer and cannot support is entitled to close
/// the connection. Echoing keeps every client that worked before this change working after it.
func negotiatedProtocolVersion(_ request: RPCRequest) -> String {
    guard let asked = request.params["protocolVersion"]?.stringValue,
          MCPProtocol.supported.contains(asked)
    else { return MCPProtocol.supported[0] }
    return asked
}

/// Routes one request. Returns nil for notifications, which must never be answered.
func handle(_ request: RPCRequest, handler: ToolHandler) async -> String? {
    if request.isNotification {
        MCPLog.debug("notification: \(request.method)")
        return nil
    }
    let id = request.id

    switch request.method {
    case "initialize":
        return JSONRPC.success(id: id, result: .object([
            // Answer in the version the client asked for, when it is one we speak.
            //
            // 2025-06-18 is what this server prefers: `outputSchema` and `structuredContent`
            // were introduced in that revision, and a tool declaring one while claiming the
            // older protocol advertises a field the client is entitled to ignore (CF-93).
            //
            // But the negotiation runs the other way round. Naming the newest revision
            // unconditionally answers a client that opened with 2024-11-05 with a protocol
            // it never offered, and a client that cannot speak it is entitled to hang up,
            // which would take the whole connection down to gain a field it was going to
            // ignore anyway. Structured content is additive and the markdown is always
            // there, so an older client loses the chip and keeps every answer (CF-94).
            "protocolVersion": .string(negotiatedProtocolVersion(request)),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string("memoir"),
                "version": .string("0.1.0"),
            ]),
            // The instructions carry two OBLIGATIONS, not just a tool index.
            //
            // In the app, an answer passes a wall of guards before anyone reads it: invented
            // figures, unsupported actions and fabricated hostnames are all caught after
            // generation and before display. None of that can run here. This server returns
            // rows and its turn ends; the prose is written afterwards, in a client, with no
            // return path, so the only lever it has on what gets asserted in its name is
            // what it asks the client to do.
            //
            // `verify` is the guard inverted: it cannot police an answer it never sees, but
            // it can let the client check itself. It has existed since the substrate landed
            // and nothing ever told a client when to call it, which made it a tool for the
            // diligent rather than a property of the system. Naming the trigger is the
            // difference.
            "instructions": .string(
                "Memoir's local work memory. The database is read-only to this server. "
                + "Lookup: `recall` (free text), `who_is` (a person), `what_happened` (a date "
                + "range), `open_commitments`, `today` (daily brief). Context: `working_set` "
                + "(what is in play right now), `what_changed_since` (catch a session up), "
                + "`prior_art` (has the user been here before). Evidence: `sources_for` (quotes "
                + "supporting a claim), `verify` (is a claim fresh, stale, or absent). Reports: "
                + "`timesheet` (per-day, per-project, measured). Recording: `propose_memory` "
                + "stages a suggestion for the user to review. It never writes memory directly."
                + "\n\n"
                + "Two obligations, because nothing here can check what you say. This server "
                + "hands back rows and stops; your sentences are written where none of Memoir's "
                + "guards can reach them.\n"
                + "1. Cite, do not assert. Every result carries provenance: which app, when. "
                + "Attribute what you report to it, and never restate a capture as something "
                + "the user did: Memoir sees what was on screen, not what was done with it.\n"
                + "2. Call `verify` before you commit a claim from this memory to anything "
                + "durable (a note, a CLAUDE.md line, a commit message), or before the user "
                + "acts on it. It answers supported / stale (with the age) / absent. Absence is "
                + "reported as absence, never as denial: capture coverage varies by app.\n\n"
                + "A lookup that is declined rather than empty says so. That is a limit of what "
                + "a screen-reading memory can know (money, meals, calls, credentials, private "
                + "browsing, the future), and rephrasing will not get past it."
            ),
        ]))

    case "ping":
        return JSONRPC.success(id: id, result: .object([:]))

    case "tools/list":
        return JSONRPC.success(id: id, result: .object([
            "tools": .array(ToolCatalog.all.map(\.listEntry))
        ]))

    case "tools/call":
        guard let name = request.params["name"]?.stringValue else {
            return JSONRPC.failure(id: id, error: RPCError(.invalidParams, "missing tool name"))
        }
        let args = request.params["arguments"] ?? .object([:])
        guard ToolCatalog.definition(named: name) != nil else {
            return JSONRPC.failure(id: id, error: RPCError(.methodNotFound, "unknown tool: \(name)"))
        }
        let result = await handler.call(name: name, arguments: args)
        // Both halves, every time. The text block stays the whole answer (it is what a
        // client without schema support reads, and the spec requires it to remain a
        // usable fallback), while `structuredContent` carries the counts the tool
        // already had and used to throw away (CF-93).
        return JSONRPC.success(id: id, result: .object([
            "content": .array([.object(["type": .string("text"), "text": .string(result.text)])]),
            "structuredContent": result.structuredContent(tool: name),
            "isError": .bool(false),
        ]))

    default:
        return JSONRPC.failure(id: id, error: RPCError(.methodNotFound, "unknown method: \(request.method)"))
    }
}

/// Writes one frame to stdout. The only place anything is written to stdout.
func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

// MARK: - Self test

enum SelfTest {
    /// Exercises the handshake and every tool against the real database,
    /// printing to stderr so it can be run without an MCP client.
    static func run(memory: MemoirMemory, handler: ToolHandler) async {
        let status = await memory.status()
        MCPLog.info("database: \(status.path)")
        MCPLog.info("status: \(status.isReady ? "ready" : "not ready")")

        for def in ToolCatalog.all {
            MCPLog.info("---- \(def.name) ----")
            let args: JSONValue
            switch def.name {
            case "recall":             args = .object(["query": .string("project"), "limit": .int(3)])
            case "who_is":             args = .object(["name": .string("anyone")])
            case "what_happened":      args = .object(["from": .string("yesterday"), "to": .string("today")])
            case "what_changed_since": args = .object(["since": .string("yesterday")])
            case "prior_art":          args = .object(["topic": .string("project")])
            case "sources_for":        args = .object(["claim": .string("project")])
            case "verify":             args = .object(["claim": .string("project")])
            case "timesheet":          args = .object(["from": .string("yesterday"), "to": .string("today")])
            case "propose_memory":
                // The one tool with a side effect. A selftest must not stage junk
                // into the user's review queue just for running.
                MCPLog.info("skipped: staging a proposal is a side effect; test via a client")
                continue
            default:                   args = .object([:])
            }
            let out = await handler.call(name: def.name, arguments: args)
            MCPLog.info("\(out.status.rawValue): \(out.summary)")
            MCPLog.info(out.text.split(separator: "\n").prefix(6).joined(separator: "\n"))
        }
        MCPLog.info("selftest complete")
    }
}
