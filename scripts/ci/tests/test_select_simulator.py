"""Functional tests for the inventory parser; these do not run Xcode or simctl."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "select_simulator.py"
IOS_26_2 = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
IOS_27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
UUID_A = "11111111-1111-4111-8111-111111111111"
UUID_B = "22222222-2222-4222-8222-222222222222"


def device(name="iPhone 17", udid=UUID_A, available=True):
    return {"name": name, "udid": udid, "isAvailable": available}


class SelectSimulatorTests(unittest.TestCase):
    def run_parser(self, inventory, runtime="26.2", *, raw=False):
        with tempfile.TemporaryDirectory() as directory:
            # Spaces exercise argument handling without shell interpolation.
            path = Path(directory) / "devices inventory.json"
            path.write_text(inventory if raw else json.dumps(inventory), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(path), "--runtime", runtime],
                capture_output=True,
                text=True,
                check=False,
            )

    def assert_failure(self, result, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn(message, result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_prints_only_selected_uuid(self):
        result = self.run_parser({"devices": {IOS_26_2: [device()]}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, UUID_A + "\n")
        self.assertEqual(result.stderr, "")

    def test_selection_uses_name_then_uuid_regardless_of_input_order(self):
        devices = [
            device("iPhone 17 Pro", UUID_A),
            device("iPhone 17", UUID_B),
            device("iPhone 17", UUID_A),
        ]
        for order in (devices, list(reversed(devices))):
            with self.subTest(order=order):
                result = self.run_parser({"devices": {IOS_26_2: order}})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, UUID_A + "\n")

    def test_excludes_other_devices_runtimes_and_unavailable_iphones(self):
        result = self.run_parser(
            {
                "devices": {
                    IOS_27: [device("iPhone 16", UUID_A)],
                    "com.apple.CoreSimulator.SimRuntime.tvOS-26-2": [device()],
                    IOS_26_2: [
                        device("iPad Pro", UUID_A),
                        device("iPhone 16", UUID_A, False),
                        device("iPhone 17", UUID_B),
                    ],
                }
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, UUID_B + "\n")

    def test_trailing_zero_version_is_equivalent(self):
        for runtime, identifier in (
            ("26.2.0", IOS_26_2),
            ("26.2", IOS_26_2 + "-0"),
        ):
            with self.subTest(runtime=runtime, identifier=identifier):
                result = self.run_parser({"devices": {identifier: [device()]}}, runtime)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, UUID_A + "\n")

    def test_fails_when_exact_runtime_is_missing_even_if_newer_exists(self):
        result = self.run_parser({"devices": {IOS_27: [device()]}})
        self.assert_failure(result, "Required iOS runtime 26.2 is absent")

    def test_tvos_does_not_satisfy_requested_ios_runtime(self):
        result = self.run_parser(
            {"devices": {"com.apple.CoreSimulator.SimRuntime.tvOS-26-2": [device()]}}
        )
        self.assert_failure(result, "Required iOS runtime 26.2 is absent")

    def test_malformed_json_fails_explicitly(self):
        result = self.run_parser("{not valid JSON", raw=True)
        self.assert_failure(result, "select_simulator:")

    def test_missing_or_invalid_devices_map_fails_explicitly(self):
        for inventory in ({}, [], None, {"devices": []}):
            with self.subTest(inventory=inventory):
                self.assert_failure(self.run_parser(inventory), "'devices' runtime map")

    def test_invalid_runtime_device_list_fails_explicitly(self):
        result = self.run_parser({"devices": {IOS_26_2: {}}})
        self.assert_failure(result, "Expected a device list")

    def test_no_iphone_fails_explicitly(self):
        for devices in ([], [device("iPad Pro")], [device("Apple TV")]):
            with self.subTest(devices=devices):
                result = self.run_parser({"devices": {IOS_26_2: devices}})
                self.assert_failure(result, "No available iPhone")

    def test_availability_must_be_boolean_true(self):
        for available in (False, None, 1, "true"):
            with self.subTest(available=available):
                result = self.run_parser(
                    {"devices": {IOS_26_2: [device(available=available)]}}
                )
                self.assert_failure(result, "No available iPhone")

    def test_missing_availability_is_not_available(self):
        candidate = device()
        del candidate["isAvailable"]
        result = self.run_parser({"devices": {IOS_26_2: [candidate]}})
        self.assert_failure(result, "No available iPhone")

    def test_invalid_udid_is_rejected_including_shell_text(self):
        for udid in ("not-a-uuid", "$(touch unexpected)", UUID_A + ";echo unsafe", None):
            with self.subTest(udid=udid):
                result = self.run_parser({"devices": {IOS_26_2: [device(udid=udid)]}})
                self.assert_failure(result, "valid UUID")

    def test_invalid_entries_do_not_hide_valid_candidate(self):
        result = self.run_parser(
            {"devices": {IOS_26_2: [None, 7, {}, device(udid="bad"), device()]}}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, UUID_A + "\n")

    def test_invalid_requested_version_fails_explicitly(self):
        result = self.run_parser({"devices": {IOS_26_2: [device()]}}, "26.2; echo unsafe")
        self.assert_failure(result, "Invalid runtime version")


if __name__ == "__main__":
    unittest.main()
