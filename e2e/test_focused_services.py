import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("focused_services.py")
BUILD_SCRIPT = Path(__file__).with_name("build-devices.sh")
ROOT = SCRIPT.parent.parent
CONFIG = {
    "services": {
        "door-lock-aliro": {"environment": {"E2E_DEVICE": "matter_door_lock_aliro"}},
        "shared-switch": {
            "environment": {
                "E2E_DEVICE": "matter_shared_switch",
                "E2E_BINARY": "matter_switch",
            }
        },
        "switch": {"environment": {"E2E_DEVICE": "matter_switch"}},
        "official-jf-migration-target": {"environment": {}},
        "tests": {},
    }
}


class FocusedServicesTest(unittest.TestCase):
    def resolve(self, *services):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *services],
            input=json.dumps(CONFIG),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_fixture_and_aliased_service(self):
        result = self.resolve("door-lock-aliro", "shared-switch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "matter_door_lock_aliro matter_switch")

    def test_duplicate_binary_is_built_once(self):
        result = self.resolve("shared-switch", "switch")
        self.assertEqual(result.stdout.strip(), "matter_switch")

    def test_sdk_target_does_not_add_a_crystal_binary(self):
        result = self.resolve("switch", "official-jf-migration-target")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "matter_switch")

    def test_unknown_service_is_rejected(self):
        result = self.resolve("typo")
        self.assertEqual(result.returncode, 2)

    def test_test_runner_cannot_be_selected(self):
        result = self.resolve("tests")
        self.assertEqual(result.returncode, 2)

    def test_focused_build_uses_only_selected_fixture_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            compiler = Path(directory) / "crystal"
            compiler.write_text("#!/bin/sh\nprintf 'MOCK %s\\n' \"$2\"\n")
            compiler.chmod(0o755)
            environment = os.environ.copy()
            environment.update({
                "PATH": f"{directory}:{os.environ['PATH']}",
                "MATTER_E2E_BINARIES": (
                    "device_validation matter_door_lock_aliro matter_door_lock_verified"
                ),
                "MATTER_E2E_BUILD_JOBS": "1",
            })
            result = subprocess.run(
                ["sh", str(BUILD_SCRIPT)],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("MOCK e2e/fixture/matter_door_lock_aliro_device.cr", result.stdout)
            self.assertIn("MOCK e2e/fixture/matter_door_lock_verified_device.cr", result.stdout)
            self.assertNotIn("matter_switch_device.cr", result.stdout)

    def test_focused_test_starts_only_selected_services(self):
        with tempfile.TemporaryDirectory() as directory:
            docker = Path(directory) / "docker"
            calls = Path(directory) / "calls"
            config = Path(directory) / "config.json"
            config.write_text(json.dumps(CONFIG))
            docker.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >> \"$FAKE_DOCKER_CALLS\"\n"
                "if [ \"$1 $2\" = 'compose config' ]; then "
                "cat \"$FAKE_DOCKER_CONFIG\"; fi\n"
                "exit 0\n"
            )
            docker.chmod(0o755)
            environment = os.environ.copy()
            environment.update({
                "PATH": f"{directory}:{os.environ['PATH']}",
                "FAKE_DOCKER_CALLS": str(calls),
                "FAKE_DOCKER_CONFIG": str(config),
            })
            result = subprocess.run(
                [
                    "bash", str(ROOT / "test"), "--focused",
                    "--service", "door-lock-aliro", "--",
                    "e2e/spec/door_lock_aliro_spec.cr",
                ],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            commands = calls.read_text().splitlines()
            self.assertIn("compose build switch", commands)
            self.assertIn("compose build tests", commands)
            self.assertIn("compose up --no-build --no-deps -d --wait door-lock-aliro", commands)
            # The one-off runner hosts the JFA HTTPS DCL mirror at https://tests.
            # Compose must register its service alias on the focused network.
            self.assertIn("compose run --rm --no-deps --use-aliases tests", commands)
            self.assertFalse(any(" shared-switch" in command for command in commands))


if __name__ == "__main__":
    unittest.main()
