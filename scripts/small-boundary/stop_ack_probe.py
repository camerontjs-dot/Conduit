"""Alter only known-stopped, owned test records; exercise the actual native gate.

This is test apparatus for one trusted campaign, not a slot-recovery API.
Every original and injected record is retained. Any failure stops the sequence
with its current evidence intact; it does not automatically free the slot.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location("guest_slot_probe", Path(__file__).with_name("guest_slot_probe.py"))
slot_probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slot_probe)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_once(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        slot_probe.require(os.write(fd, value) == len(value), "incomplete_test_record")
        os.fsync(fd)
    finally:
        os.close(fd)


def before_launch(directory, argv, ticket, capture, environment):
    slot = directory.parent / "guest-slot"
    baseline = slot_probe.snapshot(slot)
    slot_probe.require(len(baseline) == 4 and not slot_probe.unacknowledged(baseline),
                       "two_confirmed_stops_required")
    controls = []
    for name in ("older-ack-01", "current-ack-01"):
        control = directory.parent / name
        prior_ticket = (control / "native-ticket.json").read_bytes()
        fields = json.loads(prior_ticket)
        nonce = fields["nonce"]
        result = slot_probe.read(control / "RESULT.json")
        host = slot_probe.read(control / "supervisor-final.json")
        events = result["native_events"]
        slot_probe.require(result["status"] == "STOP_OBSERVED_WITH_BOUNDS" and not result["failures"]
                           and result["guest_stop"] == "STOP_OBSERVED"
                           and events[-1]["event"] == "supervisor_stop_observed"
                           and events[-1]["state"] == "stopped" and events[-1]["nonce"] == nonce
                           and host["executionCapacityReleased"] and host["processGroupAbsentObserved"]
                           and host["directChildExitObserved"]
                           and host["request"]["operationID"] == fields["fixture_operation_id"]
                           and baseline.get(nonce + ".claim") == prior_ticket
                           and baseline.get(nonce + ".stopped") == prior_ticket
                           and (control / "native-launch.claim").read_bytes() == prior_ticket,
                           "control_native_stop_or_claim_missing")
        controls.append({"case": name, "nonce": nonce, "operation_id": fields["fixture_operation_id"],
                         "result_sha256": digest(control / "RESULT.json"),
                         "host_sha256": digest(control / "supervisor-final.json")})
    fields = json.loads(ticket)
    slot_probe.require(len({x["nonce"] for x in controls} | {fields["nonce"]}) == 3
                       and len({x["operation_id"] for x in controls} | {fields["fixture_operation_id"]}) == 3
                       and not (directory / "native-launch.claim").exists(), "fresh_admission_required")
    evidence = directory / "stop-ack-matrix"
    evidence.mkdir(mode=0o700)
    originals = evidence / "original-records"
    originals.mkdir(mode=0o700)
    for name, value in baseline.items():
        write_once(originals / name, value)
    slot_probe.save(evidence / "binding.json",
                    {"controls": controls, "slot_records": slot_probe.hashes(baseline),
                     "waiting_nonce": fields["nonce"], "ticket_sha256": hashlib.sha256(ticket).hexdigest(),
                     "runner_sha256": digest(argv[0])})

    older, current = [baseline[x["nonce"] + ".claim"] for x in controls]
    stop_path = slot / (controls[1]["nonce"] + ".stopped")
    withheld = evidence / "genuine-current.stopped"
    stop_path.rename(withheld)
    altered_operation = {**json.loads(current), "fixture_operation_id": "mismatched-test-operation"}
    altered_asset = {**json.loads(current), "initrd_sha256": "0" * 64}
    cases = (("missing-current-with-older-present", None), ("stale-older-at-current-name", older),
             ("wrong-operation", json.dumps(altered_operation, sort_keys=True).encode()),
             ("wrong-initrd", json.dumps(altered_asset, sort_keys=True).encode()))
    observations = []
    for label, altered in cases:
        if altered is not None:
            slot_probe.require(altered != current, "test_record_must_differ")
            write_once(stop_path, altered)
        before = slot_probe.snapshot(slot)
        slot_probe.require(slot_probe.unacknowledged(before) == [controls[1]["nonce"]],
                           "current_claim_must_remain_unacknowledged")
        for suffix in ("", "-retry"):
            slot_probe.native_refusal(evidence, label + suffix, argv, ticket, capture, environment,
                                      "guest_slot_stop_unacknowledged")
            slot_probe.require(slot_probe.snapshot(slot) == before
                               and not (directory / "native-launch.claim").exists(),
                               "refused_admission_changed_slot_or_claim")
        observations.append({"case": label, "attempts": 2, "slot_records": slot_probe.hashes(before),
                             "native_configurations": 0, "native_starts": 0})
        if altered is not None:
            stop_path.rename(evidence / (label + ".stopped"))
    slot_probe.require(not stop_path.exists() and withheld.read_bytes() == current,
                       "genuine_ack_restore_precondition")
    withheld.rename(stop_path)
    slot_probe.require(slot_probe.snapshot(slot) == baseline, "original_slot_not_restored")
    slot_probe.save(evidence / "denial-observations.json",
                    {"cases": observations, "genuine_ack_restored": True,
                     "slot_restored_byte_for_byte": True})


def after_launch(directory):
    evidence = directory / "stop-ack-matrix"
    binding = slot_probe.read(evidence / "binding.json")
    ticket = (directory / "native-ticket.json").read_bytes()
    result = slot_probe.read(directory / "RESULT.json")
    records = slot_probe.snapshot(directory.parent / "guest-slot")
    nonce = binding["waiting_nonce"]
    slot_probe.require(digest(directory / "VMRunner") == binding["runner_sha256"]
                       and hashlib.sha256(ticket).hexdigest() == binding["ticket_sha256"]
                       and (directory / "native-launch.claim").read_bytes() == ticket
                       and records.get(nonce + ".claim") == records.get(nonce + ".stopped") == ticket
                       and len(records) == 6 and not slot_probe.unacknowledged(records)
                       and all(hashlib.sha256(records[name]).hexdigest() == expected
                               for name, expected in binding["slot_records"].items())
                       and result["status"] == "STOP_OBSERVED_WITH_BOUNDS" and not result["failures"]
                       and [x["event"] for x in result["native_events"]].count("guest_started") == 1
                       and (directory / "bridge-entries").read_bytes() == b"entered\n",
                       "matching_ack_fresh_launch_or_stop_unconfirmed")
    slot_probe.save(evidence / "RESULT.json",
                    {"status": "MATCHING_STOP_ACK_REQUIRED", "denied_admissions": 8,
                     "native_starts_during_denials": 0, "matching_ack_native_starts": 1,
                     "same_waiting_ticket_and_runner": True, "guest_stop": result["guest_stop"],
                     "guest_conditions": len(result["cases"]), "slot_records": slot_probe.hashes(records)})
