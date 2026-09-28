"""Portable source-kit guards only; never invoke the assembler or write products.

The exact kit CHANGELOG.md is a read-only regression input. Run these checks
before mechanical assembly, which deliberately changes that pinned input.
"""
import ast
import hashlib
import importlib.util
from pathlib import Path
import re
import unittest

ASSEMBLER = Path(__file__).with_name("assemble.py")
spec = importlib.util.spec_from_file_location("repair88_assembly", ASSEMBLER)
assembly = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assembly)

# Independent fixture/oracle copied from the reviewed source, not the guard's
# constant. This leading entry identifies the intended first Fixed block.
FIXED = "### Fixed\n"
FLEET_ENTRY = """
- Fleet keeps every provider inventory row visible but reads expensive
  turn/runtime detail only for sessions with a current exact Conduit task
  association or current Conduit writer authority. Skipped historical/external
  detail stays UNKNOWN with an inspectable reason; inventory alone does not
  grant authority (#75, discovered during #74).
"""
ANCHOR = FIXED + FLEET_ENTRY
REPAIR = "\n- Guard test repair.\n"
REPLACEMENT = FIXED + REPAIR
PREFIX = "# Changes\n\n## [Unreleased]\n\n### Added\n\nNew feature.\n\n"
HISTORICAL = "\n## [1.0]\n\n### Fixed\n\nOld release.\n"


def fixture(later_fixed=0):
    return (PREFIX + ANCHOR + "\nExisting second repair.\n"
            + "".join(f"\n### Fixed\n\nLater repair {i}.\n" for i in range(later_fixed))
            + HISTORICAL)


def production_replacement():
    """Inspect the existing call argument without executing main or transforms."""
    tree = ast.parse(ASSEMBLER.read_text(encoding="utf-8"))
    calls = [node for node in ast.walk(tree)
             if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
             and node.func.id == "unreleased_fixed"]
    if len(calls) != 1:
        raise AssertionError("expected one production changelog transform call")
    return ast.literal_eval(calls[0].args[1])


class AssemblyGuardTests(unittest.TestCase):
    def test_exact_anchor_does_not_accept_duplicates(self):
        with self.assertRaises(ValueError):
            assembly.once("anchor anchor", "anchor", "replacement")

    def test_missing_anchor_refuses(self):
        with self.assertRaises(ValueError):
            assembly.once("other", "anchor", "replacement")

    def test_only_reviewed_unreleased_fixed_is_changed(self):
        original = fixture()
        expected = PREFIX + FIXED + REPAIR + FLEET_ENTRY + "\nExisting second repair.\n" + HISTORICAL
        self.assertEqual(assembly.unreleased_fixed(original, REPLACEMENT), expected)

    def test_six_fixed_headings_are_not_six_target_identities(self):
        original = fixture(later_fixed=5)
        target = len(PREFIX) + len(FIXED)
        self.assertEqual(assembly.unreleased_fixed(original, REPLACEMENT),
                         original[:target] + REPAIR + original[target:])

    def test_exact_pinned_changelog_and_production_insertion(self):
        path = Path(__file__).resolve().parents[2] / "CHANGELOG.md"
        raw = path.read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        self.assertEqual(blob, "60a0bc6a22f4c8aed312388ba0b80a401a78d65e")
        self.assertEqual(blob, assembly.BLOBS["CHANGELOG.md"])
        original = raw.decode("utf-8")
        start = original.index("## [Unreleased]\n")
        end = original.index("\n## [2026-08-07]")
        self.assertEqual(len(re.findall(r"^### Fixed$", original[start:end], re.M)), 6)
        self.assertEqual(original.count(ANCHOR), 1)
        self.assertEqual(original[:original.index(ANCHOR)].count("\n") + 1, 108)
        replacement = production_replacement()
        target = original.index(ANCHOR) + len(FIXED)
        expected = original[:target] + replacement[len(FIXED):] + original[target:]
        changed = assembly.unreleased_fixed(original, replacement)
        self.assertEqual(changed.encode("utf-8"), expected.encode("utf-8"))
        # Every original byte, including the other five Fixed blocks and all
        # historical releases, survives; only the reviewed insertion is added.
        insertion = replacement[len(FIXED):]
        self.assertEqual(changed[:target] + changed[target + len(insertion):], original)
        self.assertTrue(changed.endswith(original[end:]))
        self.assertEqual(path.read_bytes(), raw)

    def test_repeated_call_is_deterministic(self):
        original = fixture(5)
        self.assertEqual(assembly.unreleased_fixed(original, REPLACEMENT),
                         assembly.unreleased_fixed(original, REPLACEMENT))

    def test_reapplying_to_postimage_refuses(self):
        changed = assembly.unreleased_fixed(fixture(5), REPLACEMENT)
        with self.assertRaisesRegex(ValueError, "content anchor"):
            assembly.unreleased_fixed(changed, REPLACEMENT)

    def test_absent_unreleased_is_not_replaced_by_prior_release(self):
        with self.assertRaisesRegex(ValueError, "one Unreleased"):
            assembly.unreleased_fixed("## [1.0]\n" + ANCHOR, REPLACEMENT)

    def test_duplicate_unreleased_refuses(self):
        with self.assertRaisesRegex(ValueError, "one Unreleased"):
            assembly.unreleased_fixed(fixture() + "\n## [Unreleased]\n", REPLACEMENT)

    def test_unreleased_must_be_a_full_line_heading(self):
        for heading in ("prefix ## [Unreleased]\n", "## [Unreleased] renamed\n"):
            with self.subTest(heading=heading), self.assertRaisesRegex(ValueError, "one Unreleased"):
                assembly.unreleased_fixed(heading + ANCHOR, REPLACEMENT)

    def test_generic_fixed_without_reviewed_entry_refuses(self):
        with self.assertRaisesRegex(ValueError, "content anchor"):
            assembly.unreleased_fixed(PREFIX + "### Fixed\n\nUnreviewed.\n", REPLACEMENT)

    def test_ambiguous_generic_fixed_without_target_refuses(self):
        with self.assertRaisesRegex(ValueError, "content anchor"):
            assembly.unreleased_fixed("## [Unreleased]\n### Fixed\nA\n### Fixed\nB\n", REPLACEMENT)

    def test_altered_reviewed_entry_refuses(self):
        with self.assertRaisesRegex(ValueError, "content anchor"):
            assembly.unreleased_fixed(fixture().replace("grant authority", "infer authority"), REPLACEMENT)

    def test_duplicate_named_anchor_in_unreleased_refuses(self):
        with self.assertRaisesRegex(ValueError, "one reviewed"):
            assembly.unreleased_fixed(PREFIX + ANCHOR + "\n" + ANCHOR + HISTORICAL, REPLACEMENT)

    def test_duplicate_named_anchor_in_history_refuses(self):
        with self.assertRaisesRegex(ValueError, "one reviewed"):
            assembly.unreleased_fixed(fixture() + ANCHOR, REPLACEMENT)

    def test_named_anchor_moved_to_later_fixed_refuses(self):
        moved = PREFIX + "### Fixed\n\nAnother block.\n\n" + ANCHOR + HISTORICAL
        with self.assertRaisesRegex(ValueError, "not the first"):
            assembly.unreleased_fixed(moved, REPLACEMENT)

    def test_named_anchor_moved_to_prior_release_refuses(self):
        moved = PREFIX + "### Fixed\n\nUnreleased repair.\n" + HISTORICAL + ANCHOR
        with self.assertRaisesRegex(ValueError, "outside Unreleased"):
            assembly.unreleased_fixed(moved, REPLACEMENT)

    def test_named_anchor_moved_before_unreleased_refuses(self):
        with self.assertRaisesRegex(ValueError, "outside Unreleased"):
            assembly.unreleased_fixed(ANCHOR + "\n" + PREFIX + HISTORICAL, REPLACEMENT)

    def test_non_release_peer_or_higher_heading_ends_scope(self):
        for heading in ("## Appendix\n", "# Appendix\n"):
            with self.subTest(heading=heading), self.assertRaisesRegex(ValueError, "outside Unreleased"):
                assembly.unreleased_fixed(PREFIX + heading + ANCHOR + HISTORICAL, REPLACEMENT)

    def test_named_anchor_in_fenced_example_refuses(self):
        for fence in ("```md\n", "~~~md\n"):
            with self.subTest(fence=fence), self.assertRaisesRegex(ValueError, "fenced content"):
                assembly.unreleased_fixed(PREFIX + fence + ANCHOR + HISTORICAL, REPLACEMENT)

    def test_replacement_cannot_drop_fixed_heading(self):
        with self.assertRaisesRegex(ValueError, "preserve the Fixed heading"):
            assembly.unreleased_fixed(fixture(), "- Repair without heading.\n")

    def test_ambiguous_method_boundaries_refuse(self):
        with self.assertRaises(ValueError):
            assembly.region("start start body end", "start", "end", lambda text: text)
        with self.assertRaises(ValueError):
            assembly.region("end body start", "start", "end", lambda text: text)


if __name__ == "__main__":
    unittest.main()
