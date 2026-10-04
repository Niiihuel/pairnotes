#!/usr/bin/env python3
"""Select a real available iPhone from saved `simctl list devices` JSON."""

import argparse
import json
import re
import sys
import uuid
from pathlib import Path


IOS_RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime.iOS-"
UUID_PATTERN = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


class SelectionError(ValueError):
    """The supplied inventory cannot satisfy the requested destination."""


def version_parts(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        raise SelectionError(f"Invalid runtime version: {value!r}")
    parts = [int(part) for part in value.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def select_simulator(inventory: object, runtime: str) -> str:
    requested_version = version_parts(runtime)
    if not isinstance(inventory, dict) or not isinstance(
        inventory.get("devices"), dict
    ):
        raise SelectionError("Expected a JSON object with a 'devices' runtime map")

    matching_devices = []
    matched_runtime = False
    for identifier, devices in inventory["devices"].items():
        if not identifier.startswith(IOS_RUNTIME_PREFIX):
            continue
        version = identifier[len(IOS_RUNTIME_PREFIX) :].replace("-", ".")
        try:
            matches = version_parts(version) == requested_version
        except SelectionError:
            continue
        if not matches:
            continue
        matched_runtime = True
        if not isinstance(devices, list):
            raise SelectionError(f"Expected a device list for {identifier}")
        matching_devices.extend(devices)

    if not matched_runtime:
        raise SelectionError(f"Required iOS runtime {runtime} is absent from inventory")

    candidates = []
    for device in matching_devices:
        if not isinstance(device, dict) or device.get("isAvailable") is not True:
            continue
        name = device.get("name")
        udid = device.get("udid")
        if not isinstance(name, str) or not name.startswith("iPhone "):
            continue
        if not isinstance(udid, str) or not UUID_PATTERN.fullmatch(udid):
            continue
        # Canonicalization ensures stable ordering even for mixed letter casing.
        canonical_udid = str(uuid.UUID(udid)).upper()
        candidates.append((name, canonical_udid))

    if not candidates:
        raise SelectionError(
            f"No available iPhone with a valid UUID for required iOS runtime {runtime}"
        )
    return min(candidates)[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path, help="Saved simctl devices JSON")
    parser.add_argument("--runtime", required=True, help="Required iOS version, e.g. 26.2")
    args = parser.parse_args()

    try:
        inventory = json.loads(args.inventory.read_text(encoding="utf-8"))
        selected = select_simulator(inventory, args.runtime)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"select_simulator: {error}", file=sys.stderr)
        return 1
    print(selected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
