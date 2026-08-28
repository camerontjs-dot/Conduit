import Foundation

/// Declarative MCP tool metadata shared by the loopback server and Core tests.
///
/// Dispatch and runtime writes remain app-target responsibilities. Keeping the
/// catalog here makes the caller-facing contract testable without AppKit.
public enum ConduitSessionToolCatalog {
    /// The published catalog is deliberately independent of local write
    /// authorization. Some MCP clients snapshot tools/list and otherwise never
    /// discover a lifecycle action after the operator enables it. The server
    /// still refuses each write at call time while its local gate is off.
    public static func tools() -> [[String: Any]] {
        readTools + writeTools
    }

    public static var readToolNames: [String] {
        names(in: readTools)
    }

    public static var writeToolNames: [String] {
        names(in: writeTools)
    }

    public static func tool(named name: String) -> [String: Any]? {
        (readTools + writeTools).first { $0["name"] as? String == name }
    }

    private static func names(in tools: [[String: Any]]) -> [String] {
        tools.compactMap { $0["name"] as? String }
    }

    private static let localReadOnlyAnnotations: [String: Any] = [
        "readOnlyHint": true,
        "openWorldHint": false,
    ]

    private static let stateChangingAnnotations: [String: Any] = [
        "readOnlyHint": false,
        "destructiveHint": true,
    ]

    private static let nonDestructiveStateChangingAnnotations: [String: Any] = [
        "readOnlyHint": false,
        "destructiveHint": false,
        "openWorldHint": false,
    ]

    private static let sessionEventsOutputSchema: [String: Any] = [
        "type": "object",
        "required": [
            "taskSessionID", "backend", "session", "turn", "observation",
            "events", "next_cursor", "has_more", "cursor_state",
            "timeline_count", "truncated", "authority",
        ],
        "properties": [
            "taskSessionID": ["type": "string"],
            "backend": ["type": "string"],
            "session": [
                "type": "object",
                "properties": [
                    "lifecycle": ["type": "string"],
                    "runtime_state": ["type": "string"],
                    "live": ["type": "boolean"],
                    "ready": ["type": "boolean"],
                ],
            ],
            "turn": [
                "type": "object",
                "properties": [
                    "state": [
                        "type": "string",
                        "enum": ["idle", "active", "completed", "awaiting_input", "ambiguous"],
                    ],
                    "status": ["type": "string"],
                    "honesty": ["type": "string"],
                    "ambiguity": ["type": "string"],
                    "thread_id": ["type": "string"],
                    "thread_id_source": [
                        "type": "string",
                        "enum": ["live", "persisted", "unavailable"],
                    ],
                    "pending_approval": ["type": "boolean"],
                ],
            ],
            "observation": [
                "type": "object",
                "required": [
                    "observed_at", "last_output_state", "checkpoint",
                    "provider_progress", "input_state", "checkpoint_authority",
                ],
                "properties": [
                    "observed_at": ["type": "string"],
                    "last_output_at": ["type": "string"],
                    "last_output_state": [
                        "type": "string",
                        "enum": ["none", "live", "settled", "closed"],
                    ],
                    "checkpoint": [
                        "type": "string",
                        "enum": [
                            "structured_active", "structured_approval",
                            "structured_completed", "structured_idle", "output_live",
                            "output_quiet", "output_unobserved", "capture_closed",
                        ],
                    ],
                    "provider_progress": [
                        "type": "string",
                        "enum": ["structured", "unavailable"],
                    ],
                    "input_state": [
                        "type": "string",
                        "enum": ["approval", "unknown", "none"],
                    ],
                    "input_summary": ["type": "string"],
                    "checkpoint_authority": ["type": "string"],
                ],
            ],
            "events": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "cursor": ["type": "string"],
                        "event_id": ["type": "string"],
                        "occurred_at": ["type": "string"],
                        "kind": ["type": "string"],
                        "authority": ["type": "string"],
                        "source": ["type": "string"],
                        "text": ["type": "string"],
                        "state": ["type": "string"],
                        // This is Conduit's text-cap marker only. An interrupt
                        // request is represented by a separate event kind.
                        "truncated": ["type": "boolean"],
                        "redacted": ["type": "boolean"],
                        "prompt_event_id": ["type": "string"],
                        "artifact_refs": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "kind": ["type": "string"],
                                    "path": ["type": "string"],
                                ],
                            ],
                        ],
                        "turn_status": ["type": "string"],
                        "content_digest": ["type": "string"],
                    ],
                ],
            ],
            "next_cursor": ["type": "string"],
            "has_more": ["type": "boolean"],
            "cursor_state": ["type": "string"],
            "timeline_count": ["type": "integer"],
            "truncated": ["type": "boolean"],
            "authority": ["type": "string"],
        ],
    ]

    private static let readTools: [[String: Any]] = [
        tool(
            "conduit_list_projects",
            "List MainFrame projects Conduit can start work in. Each entry has slug, title, and lifecycle state. The slug is what conduit_create_task takes as project_slug.",
            annotations: localReadOnlyAnnotations
        ),
        tool(
            "conduit_list_sessions",
            "List Conduit tasks, newest activity first, with the durable task UUID used by every other task tool. Paged responses always report total, returned, has_more, and next_cursor. live and ready describe an observed runtime, not agent progress.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "cursor": property("string", "Monotonic cursor from a previous next_cursor. Omit to start at the newest task. Format v1:<index>."),
                "limit": integerProperty("Maximum tasks to return. Default 40, hard cap 200.", maximum: 200),
            ]
        ),
        tool(
            "conduit_list_adapters",
            "List enabled agent profiles and their preferred session backend. Use name as the agent argument to conduit_create_task. This is a declared launch surface, not a live health check.",
            annotations: localReadOnlyAnnotations
        ),
        tool(
            "conduit_session_status",
            "Observed status for one existing Conduit task plus a short redacted conversation tail. It reads the durable log when no runtime is live. Status is observation, never verification of what an agent did.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "taskSessionID": property("string", "Task id from conduit_create_task or a conduit_list_sessions row. Poll after creating a task: ready turns true when the runtime will accept a prompt."),
            ],
            required: ["taskSessionID"]
        ),
        tool(
            "conduit_session_events",
            "Read incremental, bounded Conversation events and an additive supervisory observation snapshot for one task. Cursor, authority, provider-thread continuity, runtime attempt, and output checkpoint are explicit. interrupt_request means Conduit sent a request; it is not observed cancellation. truncated means Conduit text-cap truncation only. This is not verification.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "taskSessionID": property("string", "Durable Conduit task UUID."),
                "cursor": property("string", "Monotonic cursor from a previous next_cursor. Omit to start at the beginning. Format v1:<index>."),
                "limit": integerProperty("Maximum events to return. Default 20, hard cap 50.", maximum: 50),
            ],
            required: ["taskSessionID"],
            outputSchema: sessionEventsOutputSchema
        ),
        tool(
            "conduit_query_mindgraph",
            "Semantic search over the operator's local MindGraph index. scope selects knowledge or projects. Results are ranked nominations, not evidence; not_citable documents remain separate from results.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "question": property("string", "Free-text search phrase. Empty questions are refused."),
                "scope": [
                    "type": "string",
                    "enum": ["knowledge", "projects"],
                    "description": "Which index to search. Required; there is no blended default.",
                ],
            ],
            required: ["question", "scope"]
        ),
    ]

    private static let writeTools: [[String: Any]] = [
        tool(
            "conduit_create_task",
            "Start a Conduit agent session and return its taskSessionID. Objective delivery is attempted only once immediately. If objective_delivered is false, wait for ready then send it explicitly with conduit_send_prompt. The model remains the operator-configured profile choice; this tool has no model override. Approvals stay on the Mac. This action is always advertised so clients retain a stable catalog; Conduit refuses it unless the operator enables Session API writes locally.",
            annotations: stateChangingAnnotations,
            properties: [
                "agent": property("string", "Enabled profile name or command from conduit_list_adapters. An unlisted or disabled profile is refused."),
                "project_slug": property("string", "Existing project slug from conduit_list_projects; it sets the session working directory."),
                "objective": property("string", "Optional first prompt. If the runtime is not ready, no later automatic delivery occurs."),
                "idempotency_key": property("string", "Optional stable key for a safe repeated create. An identical repeat returns the original task."),
            ],
            required: ["agent", "project_slug"]
        ),
        tool(
            "conduit_send_prompt",
            "Add and deliver one message to an existing Conduit task. Origin is recorded as ChatGPT. Read the later response with conduit_session_events; this call is not agent completion. This action is always advertised so clients retain a stable catalog; Conduit refuses it unless the operator enables Session API writes locally.",
            annotations: nonDestructiveStateChangingAnnotations,
            properties: [
                "taskSessionID": property("string", "Task id from conduit_create_task or conduit_list_sessions."),
                "text": property("string", "Message delivered as one prompt. A second prompt queues behind an active turn rather than interrupting it."),
            ],
            required: ["taskSessionID", "text"]
        ),
        tool(
            "conduit_reconcile_task",
            "Reconnect an existing task to an identity-compatible runtime or retry its recorded provisioning target. It preserves the task ID and never deletes history. This action is always advertised so clients retain a stable catalog; Conduit refuses it unless the operator enables Session API writes locally.",
            annotations: nonDestructiveStateChangingAnnotations,
            properties: [
                "taskSessionID": property("string", "Task id to reconcile after detached, failed, or otherwise non-live runtime status."),
            ],
            required: ["taskSessionID"]
        ),
        tool(
            "conduit_interrupt",
            "Request interruption of the live runtime. The response confirms only that Conduit issued the request and records interrupt_request; it is not observed cancellation. Read conduit_session_events for later provider observation; truncated remains a separate Conduit text-cap field. This action is always advertised so clients retain a stable catalog; Conduit refuses it unless the operator enables Session API writes locally.",
            annotations: stateChangingAnnotations,
            properties: [
                "taskSessionID": property("string", "Task id from conduit_create_task or conduit_list_sessions. A live runtime is required."),
            ],
            required: ["taskSessionID"]
        ),
        tool(
            "conduit_close_session",
            "Leave the live runtime (detach durable tmux or stop a structured adapter). This does not delete task history. This action is always advertised so clients retain a stable catalog; Conduit refuses it unless the operator enables Session API writes locally.",
            annotations: stateChangingAnnotations,
            properties: [
                "taskSessionID": property("string", "Task id to leave. Explicit close frees one live-task slot."),
            ],
            required: ["taskSessionID"]
        ),
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        annotations: [String: Any],
        properties: [String: Any] = [:],
        required: [String] = [],
        outputSchema: [String: Any]? = nil
    ) -> [String: Any] {
        var inputSchema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { inputSchema["required"] = required }
        var result: [String: Any] = [
            "name": name,
            "description": description,
            "annotations": annotations,
            "inputSchema": inputSchema,
        ]
        if let outputSchema { result["outputSchema"] = outputSchema }
        return result
    }

    private static func property(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private static func integerProperty(
        _ description: String,
        maximum: Int
    ) -> [String: Any] {
        ["type": "integer", "minimum": 1, "maximum": maximum, "description": description]
    }
}
