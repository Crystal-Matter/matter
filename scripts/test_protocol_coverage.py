"""Fixture tests for the limited XML-to-Crystal declaration report."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from protocol_coverage import build_report, load_crystal_clusters, load_xml_clusters, render_markdown


FIXTURES = Path(__file__).parent / "fixtures" / "protocol_coverage"
CLUSTER_SOURCE = Path(__file__).resolve().parents[1] / "src" / "matter" / "cluster"


class ProtocolCoverageTests(unittest.TestCase):
    def test_canonical_cluster_and_family_mapping(self):
        clusters = load_xml_clusters(FIXTURES / "canonical")
        self.assertEqual(set(clusters), {0x1236, 0x1237, 0x1238})
        self.assertEqual(clusters[0x1236].revision, 4)
        self.assertEqual(clusters[0x1236].mandatory_attributes, {0x0000, 0x0004})
        self.assertEqual(clusters[0x1237].name, "First Member")
        self.assertEqual(clusters[0x1238].mandatory_attributes, {0x0000})

    def test_unconditional_mandatory_filter_and_revision(self):
        clusters = load_xml_clusters(FIXTURES / "xml")
        sample = clusters[0x1234]
        self.assertEqual(sample.revision, 3)
        self.assertEqual(sample.mandatory_attributes, {0x0000, 0x0003, 0x0006, 0x0007})

    def test_crystal_declarations_ignore_comments_and_continue_lines(self):
        clusters = load_crystal_clusters(FIXTURES / "crystal")
        sample = clusters[0x1234]
        self.assertEqual(sample.revision, 2)
        self.assertEqual(sample.attributes, {0x0000, 0x0003, 0x0007})
        self.assertEqual(sample.optional_attributes, {0x0007})

    def test_local_macro_with_literal_cluster_ids(self):
        clusters = load_crystal_clusters(FIXTURES / "crystal")
        for cluster_id in (0x1237, 0x1238):
            self.assertEqual(clusters[cluster_id].revision, 2)
            self.assertEqual(clusters[cluster_id].attributes, {0x0000, 0x0001})
            self.assertEqual(clusters[cluster_id].optional_attributes, {0x0001})

    def test_resource_monitoring_family_is_counted(self):
        clusters = load_crystal_clusters(CLUSTER_SOURCE)
        for cluster_id in (0x0071, 0x0072, 0x0079):
            self.assertEqual(clusters[cluster_id].revision, 1)
            self.assertEqual(clusters[cluster_id].attributes, set(range(6)))
            self.assertEqual(clusters[cluster_id].optional_attributes, {3, 4})

    def test_report_distinguishes_missing_cluster_revision_and_attributes(self):
        report = build_report(load_xml_clusters(FIXTURES / "xml"),
                              load_crystal_clusters(FIXTURES / "crystal"))
        implemented = report.entries[0x1234]
        self.assertEqual(implemented.missing_attributes, {0x0006})
        self.assertEqual(implemented.optional_mandatory_attributes, {0x0007})
        self.assertFalse(implemented.revision_matches)
        self.assertFalse(report.entries[0x1235].implemented)
        text = render_markdown(report, source_count=1, source_digest="fixture-digest")
        self.assertIn("0x1234", text)
        self.assertIn("0x0006", text)
        self.assertIn("0x0007 (optional)", text)
        self.assertIn("fixture-digest", text)
        self.assertIn("declaration coverage", text)
        self.assertIn("[server command and event declaration audit](protocol-command-event-coverage.md)", text)


if __name__ == "__main__":
    unittest.main()
