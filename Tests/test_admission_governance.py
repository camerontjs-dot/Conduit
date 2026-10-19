"""Lane B production wiring contracts; runtime behavior uses synthetic Swift fixtures."""
import pathlib
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
class AdmissionGovernanceTests(unittest.TestCase):
    def test_adoption_requires_admission_after_validation(self):
        app = (ROOT / 'Sources/Conduit/AppModel.swift').read_text()
        body = app.split('private func sessionAPIAdoptProviderSession(', 1)[1].split('private func sessionAPINormalizedProvider', 1)[0]
        self.assertIn('caller: ConduitSessionCaller', body)
        self.assertIn('sessionAPIDirectWriteAdmission(caller)', body)
        core = (ROOT / 'Sources/ConduitCore/ProviderSessionAuthority.swift').read_text().split('public func adoptSession(', 1)[1]
        self.assertLess(core.index('observedID == providerSessionID'), core.index('try admitWrite?()'))
        self.assertLess(core.index('try admitWrite?()'), core.index('registry.claimWriter('))
