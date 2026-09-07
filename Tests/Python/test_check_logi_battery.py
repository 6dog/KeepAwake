import importlib.util
import sys
import types
import unittest
from pathlib import Path


sys.modules.setdefault("hid", types.SimpleNamespace())
SCRIPT_PATH = Path(__file__).parents[2] / "Resources" / "check_logi_battery.py"
SPEC = importlib.util.spec_from_file_location("check_logi_battery", SCRIPT_PATH)
BATTERY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BATTERY)


class FakeDevice:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.writes = []

    def write(self, payload):
        self.writes.append(payload)

    def read(self, _length, timeout_ms):
        del timeout_ms
        return next(self.responses, [])


class BatteryReaderTests(unittest.TestCase):
    def test_voltage_curve_boundaries(self):
        self.assertEqual(BATTERY._voltage_to_percent(5000), 100)
        self.assertEqual(BATTERY._voltage_to_percent(3500), 0)
        self.assertEqual(BATTERY._voltage_to_percent(3799), 50)

    def test_hid_call_ignores_truncated_response(self):
        valid = [BATTERY.LONG, 1, 2, (3 << 4) | BATTERY.SW_ID, 90, 0, 0]
        device = FakeDevice([[BATTERY.LONG, 1, 2, 0], valid])

        response = BATTERY._hidpp_call(device, 1, 2, 3, timeout_ms=100)

        self.assertEqual(response, bytes(valid))


if __name__ == "__main__":
    unittest.main()
