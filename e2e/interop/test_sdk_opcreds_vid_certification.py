import unittest

from sdk_opcreds_vid_certification import assert_official_result


class OfficialOpCredsResultTest(unittest.TestCase):
    def test_requires_executed_test_and_final_step(self):
        output = ("Starting test from TC_OPCREDS_3_8.py: test_TC_OPCREDS_3_8 - 29 steps\n"
                  "***** Test Step 19\n***** Test Step 28\nFinal result: PASS !")
        assert_official_result(output, 0)
        with self.assertRaisesRegex(RuntimeError, "omitted step 19"):
            assert_official_result(output.replace("Test Step 19", "Test Step 18"), 0)
        with self.assertRaisesRegex(RuntimeError, "did not execute"):
            assert_official_result("Final result: PASS !", 0)
        with self.assertRaisesRegex(RuntimeError, "exited 1"):
            assert_official_result(output, 1)


if __name__ == "__main__":
    unittest.main()
