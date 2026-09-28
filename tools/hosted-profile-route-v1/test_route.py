"""Synthetic metadata transcripts only; no Codex process or private input."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("route", Path(__file__).with_name("check_route.py"))
route = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(route)


def fixture():
    scope = {key: "a" * 64 for key in route.DIGESTS}
    scope.update(argv=["app-server"], transport="stdio")
    def rpc(method, ident, params, result):
        return dict(method=method, id=ident, params=params, response=dict(id=ident, result=result))
    return dict(schema_version="hosted-profile-route-v1", runtime_subject=copy.deepcopy(route.SUBJECT),
                observed_at_utc="2026-09-28T01:28:39Z", planned_scope=copy.deepcopy(scope),
                probe_scope=scope, conduit_model_override=None, owned_probe_exited=True,
                exchanges=[rpc("initialize", 1, {"clientInfo": {"name": "conduit", "title": "Conduit", "version": "1.0"}},
                               {"initialized_notification_sent": True}),
                           rpc("model/list", 2, {"limit": 100, "includeHidden": True},
                               {"data": [{"model": route.MODEL, "supportedReasoningEfforts": [{"reasoningEffort": "max"}]}], "nextCursor": None}),
                           rpc("config/read", 3, {"cwd_sha256": "a" * 64, "includeLayers": False},
                               {"config": {"model": route.MODEL, "model_reasoning_effort": "max"}})])


class RouteTests(unittest.TestCase):
    def reject(self, doc, code=None):
        result = route.evaluate(doc)
        self.assertEqual(result["stage"], "READBACK_NOT_ESTABLISHED")
        if code:
            self.assertIn(code, result["errors"])

    def test_valid_metadata_is_never_runtime_or_auth_authority(self):
        result = route.evaluate(fixture())
        self.assertFalse(result["errors"])
        for field in ("grants_authority", "candidate_runtime_verified", "authentication_verified", "ready_for_hosted_qualification"):
            self.assertIs(result[field], False)

    def test_luna_override_is_compatible(self):
        doc = fixture(); doc["conduit_model_override"] = route.MODEL
        self.assertFalse(route.evaluate(doc)["errors"])

    def test_every_scope_difference_rejects(self):
        for key in route.DIGESTS:
            with self.subTest(key=key):
                doc = fixture(); doc["probe_scope"][key] = "b" * 64
                self.reject(doc, "scope_mismatch")

    def test_probe_config_flags_do_not_prove_candidate_settings(self):
        for flags in (["-c", 'model_reasoning_effort="max"'], ["--profile", "luna"], ["--model", route.MODEL]):
            doc = fixture(); doc["probe_scope"]["argv"] += flags
            self.reject(doc, "probe_override_or_unreviewed_launch")

    def test_matching_unreviewed_flags_still_reject(self):
        doc = fixture()
        for key in ("probe_scope", "planned_scope"):
            doc[key]["argv"] += ["--profile", "luna"]
        self.reject(doc)

    def test_sol_override_rejects(self):
        doc = fixture(); doc["conduit_model_override"] = "gpt-6-sol"
        self.reject(doc, "conduit_model_conflict")

    def test_wrong_runtime_rejects(self):
        doc = fixture(); doc["runtime_subject"]["commit"] = "0" * 40
        self.reject(doc, "runtime_subject")

    def test_missing_scope_is_unknown(self):
        doc = fixture(); del doc["probe_scope"]["codex_home_sha256"]
        self.reject(doc, "scope_shape")

    def test_config_effort_not_inferred(self):
        for value in (None, "xhigh", "medium", "MAX"):
            doc = fixture(); doc["exchanges"][2]["response"]["result"]["config"]["model_reasoning_effort"] = value
            self.reject(doc, "effective_model_or_effort_not_requested")

    def test_config_sol_rejects(self):
        doc = fixture(); doc["exchanges"][2]["response"]["result"]["config"]["model"] = "gpt-6-sol"
        self.reject(doc)

    def test_rpc_errors_and_wrong_id_reject(self):
        doc = fixture(); doc["exchanges"][2]["response"] = {"id": 3, "error": {"code": -32601}}
        self.reject(doc, "response_shape_or_error")
        doc = fixture(); doc["exchanges"][1]["response"]["id"] = 3
        self.reject(doc, "response_id")

    def test_config_cwd_must_match(self):
        doc = fixture(); doc["exchanges"][2]["params"]["cwd_sha256"] = "b" * 64
        self.reject(doc, "config_cwd_or_override")

    def test_extra_config_fields_are_not_retained(self):
        doc = fixture(); doc["exchanges"][2]["response"]["result"]["config"]["arbitrary_private_field"] = "do-not-echo"
        self.reject(doc)
        self.assertNotIn("do-not-echo", json.dumps(route.evaluate(doc)))

    def test_mutations_and_nonmetadata_reads_reject(self):
        for method in ("thread/start", "thread/resume", "turn/start", "config/value/write", "account/login/start", "account/read"):
            doc = fixture(); doc["exchanges"][2]["method"] = method
            self.reject(doc, "unpermitted_method_or_sequence")

    def test_partial_and_duplicate_catalog_reject(self):
        doc = fixture(); doc["exchanges"][1]["response"]["result"]["nextCursor"] = "next"
        self.reject(doc)
        doc = fixture(); rows = doc["exchanges"][1]["response"]["result"]["data"]; rows.append(copy.deepcopy(rows[0]))
        self.reject(doc, "model_missing_or_ambiguous")

    def test_max_must_be_advertised(self):
        doc = fixture(); doc["exchanges"][1]["response"]["result"]["data"][0]["supportedReasoningEfforts"] = [{"reasoningEffort": "xhigh"}]
        self.reject(doc, "max_not_advertised")

    def test_valid_pagination(self):
        doc = fixture(); page = copy.deepcopy(doc["exchanges"][1])
        doc["exchanges"][1]["response"]["result"] = {"data": [], "nextCursor": "next"}
        page.update(id=4); page["response"]["id"] = 4; page["params"]["cursor"] = "next"
        doc["exchanges"].insert(2, page)
        self.assertFalse(route.evaluate(doc)["errors"])

    def test_initialized_barrier_and_exit_required(self):
        doc = fixture(); doc["exchanges"][0]["response"]["result"]["initialized_notification_sent"] = False
        self.reject(doc)
        doc = fixture(); doc["owned_probe_exited"] = None
        self.reject(doc, "probe_exit_unobserved")

    def test_bool_rpc_id_and_naive_time_reject(self):
        doc = fixture(); doc["exchanges"][0]["id"] = True
        self.reject(doc, "rpc_id")
        doc = fixture(); doc["observed_at_utc"] = "2026-09-28T01:28:39"
        self.reject(doc, "timezone_required")

    def test_strict_json(self):
        for data in (b'{"a":1,"a":2}', b'{"a":NaN}', b'[]', b'x' * (route.MAX_BYTES + 1)):
            with self.subTest(data=data[:20]):
                with self.assertRaises(ValueError): route.decode(data)

    def test_numeric_booleans_reject(self):
        doc = fixture(); doc["exchanges"][1]["params"]["includeHidden"] = 1
        self.reject(doc, "model_pagination_request")
        doc = fixture(); doc["exchanges"][2]["params"]["includeLayers"] = 0
        self.reject(doc, "config_cwd_or_override")

    def test_cursor_cycle_rejects(self):
        doc = fixture(); template = copy.deepcopy(doc["exchanges"][1])
        pages = []
        for ident, current, nxt in [(2, None, "a"), (4, "a", "b"), (5, "b", "a")]:
            page = copy.deepcopy(template); page["id"] = ident; page["response"]["id"] = ident
            if current is not None: page["params"]["cursor"] = current
            page["response"]["result"] = {"data": [], "nextCursor": nxt}
            pages.append(page)
        doc["exchanges"][1:2] = pages
        self.reject(doc, "model_cursor")

    def test_input_not_mutated(self):
        doc = fixture(); before = copy.deepcopy(doc)
        route.evaluate(doc)
        self.assertEqual(doc, before)


if __name__ == "__main__":
    unittest.main()
