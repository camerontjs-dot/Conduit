"""Source contracts supplement native injected transport and lifecycle fixtures."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class OpenCodeResponseTruthContracts(unittest.TestCase):
    def test_stream_bound_precedes_string_decode(self):
        source = (ROOT / 'Sources/Conduit/OpenCodeHTTPClient.swift').read_text()
        self.assertNotIn('bytes.lines', source)
        self.assertIn('receiveSSEByte(byte)', source)
        core = (ROOT / 'Sources/ConduitCore/OpenCodeHTTPProtocol.swift').read_text()
        self.assertIn('OpenCodeSSELineDecoder', core)
        self.assertIn('2_097_152', core)

    def test_exit_uses_current_instance_guard(self):
        source = (ROOT / 'Sources/Conduit/AppModel.swift').read_text()
        wire = source.split('func wireStructured(_ client: OpenCodeHTTPClient)')[1].split('private func wireStructured')[0]
        callback = wire.split('client.onExited =')[1].split('client.onReady')[0]
        self.assertIn('self.openCode === client', callback)
