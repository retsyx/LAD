"""Part color MCP discovery and unchanged speculative batch transport."""
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_server import INSTRUCTIONS, NativeBridge, TOOLS


class PartColorMCPToolTests(unittest.TestCase):
    def test_read_colors_is_paginated_read_only_and_does_not_build(self):
        _, description, schema, read_only = next(tool for tool in TOOLS if tool[0] == "lad_get_part_colors")
        self.assertTrue(read_only)
        self.assertEqual(schema["required"], [])
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(set(schema["properties"]), {"artifactID", "offset", "limit"})
        self.assertEqual(schema["properties"]["limit"]["maximum"], 500)
        self.assertIn("Never rebuilds geometry", description)
        self.assertIn("preview is unavailable", description)

    def test_atomic_assignments_require_explicit_rgb_or_null(self):
        _, description, schema, read_only = next(tool for tool in TOOLS if tool[0] == "lad_set_part_colors")
        self.assertFalse(read_only)
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(schema["required"], ["changes"])
        batch = schema["properties"]["changes"]
        self.assertEqual((batch["minItems"], batch["maxItems"]), (1, 256))
        item = batch["items"]
        self.assertEqual(item["required"], ["partID", "color"])
        self.assertFalse(item["additionalProperties"])
        rgb, reset = item["properties"]["color"]["anyOf"]
        self.assertEqual(reset, {"type": "null"})
        self.assertFalse(rgb["additionalProperties"])
        self.assertEqual(set(rgb["required"]), {"red", "green", "blue"})
        for component in rgb["properties"].values():
            self.assertEqual(component, {"type": "number", "minimum": 0, "maximum": 1})
        for phrase in ("atomic batch", "conflicting overlaps", "color:null", "matching artifact patch"):
            self.assertIn(phrase, description)
        self.assertIn("without rebuilding geometry", INSTRUCTIONS)
        self.assertIn("one current RGB value", INSTRUCTIONS)
        self.assertIn("last successful color assignment", INSTRUCTIONS)
        self.assertNotIn("authored/override", description)

    def test_get_and_set_reach_native_host_with_resets_and_artifact_scope_intact(self):
        calls = [("lad_get_part_colors", {"artifactID": "candidate", "offset": 100, "limit": 25}),
                 ("lad_set_part_colors", {"artifactID": "candidate", "changes": [
                     {"partID": "case", "color": {"red": 0.8, "green": 0.2, "blue": 0.1}},
                     {"partID": "board", "color": None}]})]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            control = root / ".lad-tools"
            requests, responses = control / "requests", control / "responses"
            requests.mkdir(parents=True)
            responses.mkdir()
            bridge = NativeBridge(root)
            received = []

            def host():
                handled = set()
                deadline = time.monotonic() + 4
                while len(received) < len(calls) and time.monotonic() < deadline:
                    for pending in requests.glob("*.json"):
                        if pending.name in handled:
                            continue
                        handled.add(pending.name)
                        request = json.loads(pending.read_text())
                        received.append((request["name"], request["arguments"]))
                        result = {"content": [{"type": "text", "text": json.dumps(request["arguments"])}]}
                        temporary = responses / (request["id"] + ".tmp")
                        temporary.write_text(json.dumps(result))
                        temporary.replace(responses / (request["id"] + ".json"))
                    time.sleep(0.01)
                if len(received) != len(calls):
                    (control / "closed").write_text("host ended")

            worker = threading.Thread(target=host)
            worker.start()
            try:
                with patch("agent_server.os.kill"):
                    for name, arguments in calls:
                        result = bridge.call(name, arguments)
                        self.assertEqual(json.loads(result["content"][0]["text"]), arguments)
            finally:
                worker.join(timeout=5)
                os.close(bridge.request_fd)
                os.close(bridge.response_fd)
            self.assertFalse(worker.is_alive())
            self.assertEqual(received, calls)
            self.assertFalse(list(responses.iterdir()))


if __name__ == "__main__":
    unittest.main()
