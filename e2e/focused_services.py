#!/usr/bin/env python3
"""Resolve selected Compose services to the binaries needed by focused E2E."""

import json
import sys


def main():
    config = json.load(sys.stdin)
    binaries = []
    for service in sys.argv[1:]:
        definition = config.get("services", {}).get(service)
        if definition is None or service == "tests":
            raise ValueError(f"Unknown or invalid focused E2E service: {service}")
        environment = definition.get("environment", {})
        if isinstance(environment, list):
            environment = dict(item.split("=", 1) for item in environment)
        binary = environment.get("E2E_BINARY", environment.get("E2E_DEVICE"))
        if binary is None:
            if service not in ("official-group-recipient", "official-jf-migration-target"):
                raise ValueError(f"Focused E2E service has no device binary: {service}")
            continue
        if binary not in binaries:
            binaries.append(binary)
    print(" ".join(binaries))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(2)
