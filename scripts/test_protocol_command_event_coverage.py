"""Fixture tests for the canonical Matter command/event declaration report."""

import sys
import unittest
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from protocol_command_event_coverage import load_xml_members, load_crystal_members, build_report, render_markdown

FIXTURES = Path(__file__).parent / "fixtures" / "command_event_coverage"


class CommandEventCoverageTests(unittest.TestCase):
    def test_canonical_command_direction_and_conformance(self):
        xml = load_xml_members(FIXTURES / "xml")
        sample = xml[0x1234]
        self.assertEqual(set(xml), {0x1234, 0x1235, 0x1236})
        self.assertEqual(set(xml[0x1235].events), {0})
        self.assertEqual(set(sample.commands), {0, 1, 2, 3})
        self.assertEqual(sample.commands[0].requirement, "mandatory")
        self.assertEqual(sample.commands[2].requirement, "conditional")
        self.assertIn("TEST", sample.commands[2].condition)
        self.assertEqual(sample.commands[3].requirement, "conditional")
        self.assertEqual(sample.events[0].requirement, "mandatory")
        self.assertEqual(sample.events[1].requirement, "optional")

    def test_crystal_dsl_and_gap_report_at_advertised_revision(self):
        xml = load_xml_members(FIXTURES / "xml")
        crystal = load_crystal_members(FIXTURES / "crystal")
        self.assertEqual(crystal[0x1234].commands[2], ":test")
        self.assertEqual(crystal[0x1234].commands[4], "[:test, :other]")
        self.assertEqual(crystal[0x1234].events[3], ":test")
        report = build_report(xml, crystal)
        sample = report[0x1234]
        self.assertEqual(sample.missing_mandatory_commands, {1})
        self.assertEqual(sample.missing_mandatory_events, {0})
        self.assertEqual(sample.revision_conditional_commands, {3})
        self.assertEqual(sample.feature_conditional_commands, {2})
        revised = replace(sample, crystal=replace(sample.crystal, revision=4))
        self.assertEqual(revised.missing_mandatory_commands, {1, 3})
        text = render_markdown(report, source_count=2, source_digest="fixture-digest")
        self.assertIn("fixture-digest", text)
        self.assertIn("0x0001", text)
        self.assertIn("feature(TEST)", text)
        self.assertIn("Feature or complex conditional IDs absent from Crystal: 0", text)
        self.assertIn("Feature or complex conditional IDs declared without literal `requires:`: 1", text)
        self.assertIn("not a completeness claim", text)


if __name__ == "__main__":
    unittest.main()
