import unittest
from pathlib import Path

from sdk_opcreds_vid_certification import assert_official_result


REAL_SDK_LOG = (Path(__file__).parent / "fixtures/opcreds_3_8_pass.log").read_text()


class OfficialOpCredsResultTest(unittest.TestCase):
    def test_accepts_pinned_sdk_pass_log(self):
        # Lines copied from the actual v1.6.0.0 run 39856959576, which passed
        # every protocol step but exposed the old runner's invented log format.
        assert_official_result(REAL_SDK_LOG, 0)

    def test_requires_official_script_path(self):
        output = REAL_SDK_LOG.replace("/TC_OPCREDS_3_8.py:", "/unrelated.py:")
        with self.assertRaisesRegex(RuntimeError, "script path missing"):
            assert_official_result(output, 0)

    def test_requires_every_step(self):
        for step in range(29):
            with self.subTest(step=step):
                output = "\n".join(
                    line for line in REAL_SDK_LOG.splitlines()
                    if f"***** Test Step {step} :" not in line
                )
                with self.assertRaisesRegex(RuntimeError, f"omitted step {step}"):
                    assert_official_result(output, 0)

    def test_requires_test_method_pass(self):
        output = REAL_SDK_LOG.replace("[Test] test_TC_OPCREDS_3_8 PASS", "[Test] test_TC_OPCREDS_3_8 FAIL")
        with self.assertRaisesRegex(RuntimeError, "test method PASS"):
            assert_official_result(output, 0)

    def test_rejects_skipped_or_failed_summary(self):
        for old, new in (("Skipped 0", "Skipped 1"), ("Failed 0", "Failed 1")):
            with self.subTest(field=old):
                output = REAL_SDK_LOG.replace(old, new)
                with self.assertRaisesRegex(RuntimeError, "summary"):
                    assert_official_result(output, 0)

    def test_requires_summary_and_zero_exit(self):
        output = "\n".join(line for line in REAL_SDK_LOG.splitlines() if not line.startswith("Test results:"))
        with self.assertRaisesRegex(RuntimeError, "summary"):
            assert_official_result(output, 0)
        with self.assertRaisesRegex(RuntimeError, "exited 1"):
            assert_official_result(REAL_SDK_LOG, 1)


if __name__ == "__main__":
    unittest.main()
