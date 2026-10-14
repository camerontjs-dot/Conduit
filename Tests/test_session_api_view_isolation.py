from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sources" / "Conduit" / "AppModel.swift"

class HostedPromptPresentationContract(unittest.TestCase):
    def test_session_api_delivery_never_calls_human_project_selection(self):
        source = APP.read_text(encoding="utf-8")
        beginning = source.index("    private func sessionAPIDeliver(")
        ending = source.index("    private func sessionAPILifecycleSnapshot(", beginning)
        api_delivery = source[beginning:ending]
        self.assertIn("runtime.recordPrompt(", api_delivery)
        self.assertIn("runtime.controller.deliverPrompt(", api_delivery)
        self.assertNotIn(
            "selectSession(", api_delivery,
            "The hosted API must not inject human-UI project-selection errors after prompt acceptance."
        )

    def test_hosted_prompt_preserves_the_human_conversation_pane(self):
        source = APP.read_text(encoding="utf-8")
        beginning = source.index("    private func sessionAPIDeliver(")
        ending = source.index("    private func sessionAPILifecycleSnapshot(", beginning)
        api_delivery = source[beginning:ending]
        self.assertNotIn(
            "runtime.selectedSurface = .conversation", api_delivery,
            "An MCP/API send must not switch the human view from Raw to Conversation."
        )
        self.assertGreater(
            source.count("runtime.selectedSurface = .conversation"), 1,
            "Human presentation control should remain available outside hosted delivery."
        )

    def test_human_ui_selection_still_rejects_wrong_project(self):
        source = APP.read_text(encoding="utf-8")
        beginning = source.index("    func selectSession(_ runtime:")
        ending = source.index("    func requestTaskSearchFocus(", beginning)
        human_selection = source[beginning:ending]
        self.assertIn("session(openRuntime, belongsTo: project)", human_selection)
        self.assertIn("That session does not belong to the selected project.", human_selection)

if __name__ == "__main__":
    unittest.main()
