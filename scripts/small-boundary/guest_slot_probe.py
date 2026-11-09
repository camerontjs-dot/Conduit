"""Read actual native refusal and stop records for the owned slot experiment."""
import hashlib
import json


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def read(path):
    return json.loads(path.read_text())


def snapshot(slot):
    records = {}
    entries = sorted(slot.iterdir())
    require(len(entries) <= 16, "unexpected_slot_record_count")
    for entry in entries:
        require(entry.is_file() and not entry.is_symlink() and entry.stat().st_size <= 16384,
                "unexpected_slot_record_type")
        records[entry.name] = entry.read_bytes()
    return records


def unacknowledged(records):
    return sorted(name.removesuffix(".claim") for name in records if name.endswith(".claim")
                  and records.get(name.removesuffix(".claim") + ".stopped") != records[name])


def hashes(records):
    return {name: hashlib.sha256(value).hexdigest() for name, value in records.items()}


def save(path, facts):
    with path.open("x") as stream:
        json.dump(facts, stream, indent=2)
        stream.write("\n")


def native_refusal(directory, label, argv, ticket, capture, environment, reason):
    result = capture(argv, environment, 6, 256 * 1024, capability=ticket)
    for stream in ("stdout", "stderr"):
        (directory / (label + "." + stream)).write_bytes(result.pop(stream))
    events = [json.loads(line) for line in (directory / (label + ".stderr")).read_bytes().splitlines()]
    result.update(events=events, expected=reason)
    save(directory / (label + ".json"), result)
    require(result["exit_code"] == 77 and not result["host_timeout"] and not result["capture_truncated"]
            and result["observed_bytes"]["stdout"] == 0
            and events == [{"event": "authority_refused", "detail": reason}], "native_slot_refusal_missing")
    return result


def after_timeout(directory, slot, mode, argv, ticket, capture, environment):
    fields = json.loads(ticket)
    nonce = fields["nonce"]
    before = snapshot(slot)
    require(before.get(nonce + ".claim") == ticket, "slot_claim_missing")
    host = read(directory / "supervisor-final.json")
    require(host["phase"] == "timed_out" and host["executionCapacityReleased"]
            and host["processGroupAbsentObserved"] and host["directChildExitObserved"], "host_cleanup_required")
    require(host["request"]["operationID"] == fields["fixture_operation_id"], "host_slot_identity_mismatch")
    guest = read(directory / "RESULT.json")
    if mode == "cooperative":
        require(not unacknowledged(before) and before.get(nonce + ".stopped") == ticket
                and guest["guest_stop"] == "STOP_OBSERVED", "native_slot_stop_ack_missing")
        reason = "fixture_claim_unavailable_or_replay"
        host_replay = False
    else:
        require(unacknowledged(before) == [nonce] and guest["guest_stop"] == "UNKNOWN", "missing_stop_precondition")
        for label in ("supervisor-replay.json", "supervisor-reader-replay.json"):
            replay = read(directory / label)
            require(replay["idempotentReplay"] and replay["request"] == host["request"]
                    and replay["transitions"] == host["transitions"] and replay["phase"] == host["phase"]
                    and replay["supervision"]["attemptNonce"] == host["supervision"]["attemptNonce"],
                    "host_retry_receipt_changed")
        require((directory / "bridge-entries").read_bytes() == b"entered\n", "duplicate_bridge_entry")
        reason = "guest_slot_stop_unacknowledged"
        host_replay = True
    original_claim = (directory / "native-launch.claim").read_bytes()
    native_refusal(directory, "native-ticket-retry", argv, ticket, capture, environment, reason)
    require(snapshot(slot) == before and (directory / "native-launch.claim").read_bytes() == original_claim,
            "retry_changed_native_claim_or_slot")
    save(directory / "guest-slot-observations.json",
         {"mode": mode, "guest_stop": guest["guest_stop"], "host_capacity_released": True,
          "host_replay_returned": host_replay, "native_retry_refusal": reason, "slot_records": hashes(before),
          "unacknowledged": unacknowledged(before), "operation_id": fields["fixture_operation_id"]})
    return 0


def fresh_refusal(directory, slot, argv, ticket, capture, environment):
    fields = json.loads(ticket)
    before = snapshot(slot)
    pending = unacknowledged(before)
    require(len(pending) == 1 and fields["nonce"] + ".claim" not in before, "fresh_block_probe_precondition")
    prior = json.loads(before[pending[0] + ".claim"])
    require(prior["fixture_operation_id"] != fields["fixture_operation_id"], "fresh_operation_required")
    require(not (directory / "native-launch.claim").exists(), "unexpected_prior_native_claim")
    for label in ("fresh-native-admission", "fresh-native-admission-retry"):
        native_refusal(directory, label, argv, ticket, capture, environment, "guest_slot_stop_unacknowledged")
        require(snapshot(slot) == before and not (directory / "native-launch.claim").exists(),
                "blocked_attempt_had_native_effects")
    facts = {"status": "FRESH_AND_REPEATED_ADMISSION_REFUSED", "guest_stop": "UNKNOWN",
             "unacknowledged": pending, "slot_records": hashes(before), "native_launches": 0,
             "fresh_operation_id": fields["fixture_operation_id"], "blocked_operation_id": prior["fixture_operation_id"]}
    save(directory / "RESULT.json", facts)
    print(json.dumps({"status": facts["status"], "native_launches": 0, "slot_unchanged": True}, indent=2))
    return 0
