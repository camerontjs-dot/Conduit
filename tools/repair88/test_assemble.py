"""Builder checks for exact-anchor assembly mechanics, not app qualification."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("repair88_assembly", Path(__file__).with_name("assemble.py"))
assembly = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assembly)


class AssemblyGuardTests(unittest.TestCase):
    def test_exact_anchor_does_not_accept_duplicates(self):
        with self.assertRaises(ValueError):
            assembly.once("anchor anchor", "anchor", "replacement")

    def test_missing_anchor_refuses(self):
        with self.assertRaises(ValueError):
            assembly.once("other", "anchor", "replacement")

    def test_only_unreleased_fixed_is_changed(self):
        historical = "## [1.0]\n### Fixed\nOld release.\n"
        original = "# Changes\n## [Unreleased]\n### Added\nNew feature.\n### Fixed\nExisting repair.\n" + historical
        changed = assembly.unreleased_fixed(original, "### Fixed\nNew repair.\n")
        self.assertIn("### Fixed\nNew repair.\nExisting repair.", changed)
        self.assertTrue(changed.endswith(historical))

    def test_absent_unreleased_is_not_replaced_by_prior_release(self):
        with self.assertRaises(ValueError):
            assembly.unreleased_fixed("## [1.0]\n### Fixed\nOld.\n", "replacement")

    def test_ambiguous_unreleased_fixed_refuses(self):
        with self.assertRaises(ValueError):
            assembly.unreleased_fixed("## [Unreleased]\n### Fixed\nA\n### Fixed\nB\n", "replacement")

    def test_ambiguous_method_boundaries_refuse(self):
        with self.assertRaises(ValueError):
            assembly.region("start start body end", "start", "end", lambda text: text)
        with self.assertRaises(ValueError):
            assembly.region("end body start", "start", "end", lambda text: text)


if __name__ == "__main__":
    unittest.main()
