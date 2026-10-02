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
                        "enum": ["idle", "active", "completed", "failed", "awaiting_input", "ambiguous"],
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
                            "structured_completed", "structured_failed",
                            "structured_idle", "output_live",
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
            "List enabled agent profiles and their preferred session backend. Use name as the agent argument to conduit_create_task. This is a declared launch surface, not a live health check. structured false means a PTY agent: it has no turn protocol, so its turn.state NEVER becomes completed and polling one for completion waits forever. Orchestrate through a structured profile, or confirm PTY work from the pane yourself.",
            annotations: localReadOnlyAnnotations
        ),
        tool(
            "conduit_list_provider_sessions",
            "Read provider-native session inventory without creating or adopting a Conduit task. This is observation only: it does not send input, resume or interrupt a turn, acquire writer authority, or consume a live execution slot. OpenCode persistence is provider-observed state, not proof of a live OS process; unsupported bindings remain UNKNOWN.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "provider": [
                    "type": "string",
                    "enum": ["opencode"],
                    "description": "Provider observation implementation. Wave 1 supports opencode only.",
                ],
            ],
            required: ["provider"]
        ),
        tool(
            "conduit_fleet_snapshot",
            "Read one versioned Fleet and handoff projection over Conduit's durable task records, persisted adapter thread handles, read-only OpenCode session observations, writer authority, current lifecycle/process observations, and Slice 7 reconciliation. Tasks and provider sessions have independent cursors. Persisted runtime facts are marked stale after restart; unsupported facts stay UNKNOWN. Discovered sessions are not adopted, and this read creates no task or turn, sends no input, claims no lease, runs no cleanup, and reserves no execution slot.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "task_cursor": property("string", "Cursor from a prior task page next_cursor. Omit to start at the newest task."),
                "provider_cursor": property("string", "Independent cursor from a prior provider page next_cursor. Omit to start at the first provider session."),
                "limit": integerProperty("Maximum rows in each page. Default 40, hard cap 200.", maximum: 200),
            ]
        ),
        tool(
            "conduit_observe_worker",
            "Read one exact provider session into WorkerLineage, with separately stamped provider-persisted activity and exact-binding Slice 6A process reconciliation where available. Contradictory or stale authorities remain explicit; observation never adopts or controls the session, starts a turn, cleans processes, or promotes provider completion into objective acceptance. Missing facts remain UNKNOWN.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "provider": [
                    "type": "string",
                    "enum": ["opencode"],
                    "description": "Provider observation implementation. Wave 1 supports opencode only.",
                ],
                "provider_session_id": property(
                    "string",
                    "Exact provider-native session id returned by conduit_list_provider_sessions."
                ),
            ],
            required: ["provider", "provider_session_id"]
        ),
        tool(
            "conduit_lifecycle_preflight",
            "Read the consequences Conduit currently knows for one exact lifecycle operation before mutation. support is supported, unsupported, or unknown; provider stop, execution-capacity release, recoverability, resume handle, process scope, side effects, unsupported consequences, and unknown consequences remain separate. This call is read-only and does not reserve or release authority.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "taskSessionID": property("string", "Durable Conduit task UUID."),
                "operation": [
                    "type": "string",
                    "enum": [
                        "observe",
                        "adopt",
                        "start_turn",
                        "abort_turn",
                        "release_supervision",
                        "stop_provider_host",
                        "archive_provider_history",
                    ],
                    "description": "Exact lifecycle operation to inspect or execute.",
                ],
            ],
            required: ["taskSessionID", "operation"]
        ),
        tool(
            "conduit_session_status",
            "Observed status for one existing Conduit task plus a short redacted conversation tail. It reads the durable log when no runtime is live. close_outcome says whether conduit_close_session would be reversible for this task. prompts_held_pending_ready counts objectives Conduit accepted before the runtime was ready and still owes delivery on. thread_provenance says where the live structured session came from: resumed means the provider honoured the earlier thread, restarted means it refused and this is a NEW EMPTY session whose displaced id is superseded_thread_id, unverified means continuity was never confirmed, fresh means nobody asked to resume. Treat restarted and unverified as history you do not have. Status is observation, never verification of what an agent did.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "taskSessionID": property("string", "Task id from conduit_create_task or a conduit_list_sessions row. Poll after creating a task: ready turns true when the runtime will accept a prompt."),
            ],
            required: ["taskSessionID"]
        ),
        tool(
            "conduit_process_tree",
            "Read the current OS process topology for one task's identity-bound launcher and reconcile it with the last recorded snapshot when available. Reports launcher PID/PGID, observed descendants, parent relationships at observation time, start identities, task-created versus pre-existing versus UNKNOWN ownership, observed exits, residual descendants, and an explicit postcondition. Parent exit alone never becomes complete; this call is read-only and does not signal or clean up any process.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "taskSessionID": property(
                    "string",
                    "Durable Conduit task UUID from conduit_create_task or conduit_list_sessions."
                ),
            ],
            required: ["taskSessionID"]
        ),
        tool(
            "conduit_session_events",
            "Read incremental, bounded Conversation events and an additive supervisory observation snapshot for one task. Cursor, authority, provider-thread continuity, runtime attempt, and output checkpoint are explicit. turn.state failed and checkpoint structured_failed mean the provider reported a failure and produced no result — never treat that as completion. interrupt_request means Conduit sent a request; it is not observed cancellation. truncated means Conduit text-cap truncation only. This is not verification.",
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
            "Semantic search over the operator's local MindGraph index. scope selects knowledge, projects or operations. Results are ranked nominations, not evidence; not_citable documents remain separate from results.",
            annotations: localReadOnlyAnnotations,
            properties: [
                "question": property("string", "Free-text search phrase. Empty questions are refused."),
                "scope": [
                    "type": "string",
                    "enum": ["knowledge", "projects", "operations"],
                    "description": "Which index to search. Required; there is no blended default.",
                ],
            ],
            required: ["question", "scope"]
        ),
    ]

    private static let writeTools: [[String: Any]] = [
        tool(
            "conduit_adopt_provider_session",
            "Explicitly claim Conduit writer/controller authority for one existing provider session. This does not create, resume, replace, prompt, interrupt, or otherwise mutate the provider session. A competing controller is returned as writer_collision and the original session identity/history remain authoritative. controller_id is an opaque Conduit supervisory identity, not an authentication credential. This authority is separate from any #57 workspace/worktree writer lease. External writer ownership remains UNKNOWN unless independently observed.",
            annotations: nonDestructiveStateChangingAnnotations,
            properties: [
                "provider": [
                    "type": "string",
                    "enum": ["opencode"],
                    "description": "Provider authority adapter. Wave 1 supports opencode only.",
                ],
                "provider_session_id": property(
                    "string",
                    "Exact existing provider session id returned by conduit_list_provider_sessions."
                ),
                "controller_id": property(
                    "string",
                    "Stable opaque identity for the Conduit supervisor/controller claiming this provider session. This is governance identity, not authentication."
                ),
            ],
            required: ["provider", "provider_session_id", "controller_id"]
        ),
        tool(
            "conduit_create_task",
            "Start a Conduit agent session and return its taskSessionID. Read objective_delivery_state, not objective_delivered, to decide what to do next: delivered means it reached the runtime; queued means Conduit owns delivery and will complete it without another call, so resending would run the objective twice; failed means the runtime refused it and objective_resend_required is true, so wait for ready then send it with conduit_send_prompt. The model remains the operator-configured profile choice; this tool has no model override. Approvals stay on the Mac. This action is always advertised so clients retain a stable catalog; Conduit refuses it unless the operator enables Session API writes locally.",
            annotations: stateChangingAnnotations,
            properties: [
                "agent": property("string", "Enabled profile name or command from conduit_list_adapters. An unlisted or disabled profile is refused."),
                "project_slug": property("string", "Existing project slug from conduit_list_projects; it sets the session working directory."),
                "objective": property("string", "Optional first prompt. A structured runtime is normally still starting when this returns; Conduit holds the objective and delivers it when the runtime reports ready, which is what objective_delivery_state queued means. Do not resend a queued objective."),
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
                "text": property("string", "Message delivered as one prompt. A second prompt queues behind an active turn rather than interrupting it. If the runtime is still starting, Conduit holds this prompt and delivers it on ready rather than refusing it."),
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
            "conduit_lifecycle_operation",
            "Execute one explicit lifecycle operation only when the preflight for the same live target reports supported. Unsupported or unknown operations fail closed and are not remapped to another verb. observe, adopt, and start_turn remain separate existing surfaces; provider-history archive/delete is currently unsupported.",
            annotations: stateChangingAnnotations,
            properties: [
                "taskSessionID": property("string", "Durable Conduit task UUID."),
                "operation": [
                    "type": "string",
                    "enum": [
                        "observe",
                        "adopt",
                        "start_turn",
                        "abort_turn",
                        "release_supervision",
                        "stop_provider_host",
                        "archive_provider_history",
                    ],
                    "description": "Exact lifecycle operation to inspect or execute.",
                ],
            ],
            required: ["taskSessionID", "operation"]
        ),
        tool(
            "conduit_interrupt",
            "Compatibility interrupt surface. Structured backends request their provider-native abort/cancel; PTY backends send raw Ctrl-C, which is not a provider-defined turn-abort contract. The response confirms only that Conduit issued the request and records interrupt_request; it is not observed cancellation. Use conduit_lifecycle_preflight + abort_turn when the typed lifecycle distinction matters.",
            annotations: stateChangingAnnotations,
            properties: [
                "taskSessionID": property("string", "Task id from conduit_create_task or conduit_list_sessions. A live runtime is required."),
            ],
            required: ["taskSessionID"]
        ),
        tool(
            "conduit_close_session",
            "Compatibility close surface. tmux detach is recoverable through its exact runtime handle. Direct PTY close is not recoverable as the same live runtime and termination is asynchronous. Structured adapters stop their Conduit host/client; that live runtime is not recoverable, while provider-owned session history may remain recoverable through an exact provider handle and is never deleted by close. Use conduit_lifecycle_preflight and an explicit lifecycle operation when the caller must know provider-host, capacity, and recoverability consequences before mutation.",
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
