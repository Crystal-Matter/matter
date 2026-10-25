#!/usr/bin/env python3
"""Report limited Matter XML to Crystal cluster declaration coverage.

This compares IDs, revisions, and unconditional mandatory server attribute IDs.
It does not evaluate feature expressions or verify runtime protocol behavior.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


CLUSTER_DECLARATION = re.compile(
    r"^\s*cluster\s+(0x[0-9a-fA-F]+|\d+)\s*,\s*revision:\s*(\d+)\b",
    re.MULTILINE,
)
LOCAL_MACRO = re.compile(
    r"(?ms)^([ \t]*)macro[ \t]+([A-Za-z_]\w*)\(([^)\n]*)\)[ \t]*\n(.*?)^\1end[ \t]*$"
)
LITERAL_MACRO_ARGUMENT = re.compile(r"(?:[A-Za-z_]\w*|0x[0-9a-fA-F]+|\d+)\Z")
ATTRIBUTE_DECLARATION = re.compile(
    r"^\s*attribute\s+(0x[0-9a-fA-F]+|\d+)\s*,",
    re.MULTILINE,
)
OPTIONAL_LITERAL = re.compile(r"\boptional:\s*true\b")
CONDITIONAL_CONFORMANCE = {
    "optionalConform",
    "otherwiseConform",
    "provisionalConform",
    "disallowConform",
}
DEFAULT_NOTES = Path(__file__).resolve().parents[1] / "docs" / "protocol-coverage-notes.json"


@dataclass(frozen=True)
class XmlCluster:
    cluster_id: int
    name: str
    revision: int | None
    mandatory_attributes: frozenset[int]
    filename: str


@dataclass(frozen=True)
class CrystalCluster:
    cluster_id: int
    revision: int
    attributes: frozenset[int]
    optional_attributes: frozenset[int]
    filename: str


@dataclass(frozen=True)
class CoverageEntry:
    xml: XmlCluster
    crystal: CrystalCluster | None

    @property
    def implemented(self) -> bool:
        return self.crystal is not None

    @property
    def revision_matches(self) -> bool | None:
        if self.crystal is None or self.xml.revision is None:
            return None
        return self.crystal.revision == self.xml.revision

    @property
    def missing_attributes(self) -> frozenset[int]:
        if self.crystal is None:
            return self.xml.mandatory_attributes
        return self.xml.mandatory_attributes - self.crystal.attributes

    @property
    def optional_mandatory_attributes(self) -> frozenset[int]:
        if self.crystal is None:
            return frozenset()
        return self.xml.mandatory_attributes & self.crystal.optional_attributes


@dataclass(frozen=True)
class CoverageReport:
    entries: dict[int, CoverageEntry]
    crystal_only: frozenset[int]


def declaration_sources(source: str) -> list[str]:
    """Include simple local macros instantiated with literal arguments.

    This is a narrowly scoped declaration audit, not a Crystal macro evaluator.
    The expansion covers the cluster-family pattern used by Resource Monitoring.
    """
    # A macro body is not an instantiated cluster by itself. Scan only its
    # literal call expansions, alongside ordinary declarations outside macros.
    results = [LOCAL_MACRO.sub("", source)]
    for macro in LOCAL_MACRO.finditer(source):
        _, name, parameters_text, body = macro.groups()
        if not re.search(r"\bcluster\s+\{\{", body):
            continue
        parameters = [part.strip() for part in parameters_text.split(",")]
        if not parameters or any(not re.fullmatch(r"[A-Za-z_]\w*", part) for part in parameters):
            raise ValueError(f"Unsupported cluster macro parameters: {name}")
        invocation = re.compile(rf"(?m)^[ \t]*{re.escape(name)}[ \t]+([^\n]+)$")
        for call in invocation.finditer(source):
            arguments = [part.strip() for part in call.group(1).split(",")]
            if len(arguments) != len(parameters) or any(
                not LITERAL_MACRO_ARGUMENT.fullmatch(part) for part in arguments
            ):
                raise ValueError(f"Unsupported cluster macro invocation: {call.group(0).strip()}")
            expanded = body
            for parameter, argument in zip(parameters, arguments):
                expanded = re.sub(r"\{\{\s*" + re.escape(parameter) + r"\s*\}\}", argument, expanded)
            results.append(expanded)
    return results


def _unconditional_mandatory(attribute: ET.Element) -> bool:
    if attribute.get("optional", "false").lower() == "true":
        return False
    for child in attribute:
        if child.tag in CONDITIONAL_CONFORMANCE:
            return False
        if child.tag == "mandatoryConform" and len(child):
            return False
    return True


def _revision_only_condition(condition: ET.Element, revision: int | None) -> bool:
    """Resolve only a current-revision threshold; leave other terms unknown."""
    if revision is None or condition.tag != "greaterOrEqualTerm":
        return False
    operands = list(condition)
    if len(operands) != 2 or any(operand.tag != "revision" for operand in operands):
        return False
    if operands[0].get("value") != "current":
        return False
    try:
        threshold = int(operands[1].get("value", ""), 0)
    except ValueError:
        return False
    return revision >= threshold


def _canonical_mandatory(attribute: ET.Element, revision: int | None) -> bool:
    """Count only direct or revision-only mandatory conformance."""
    if any(child.tag == "mandatoryConform" and not len(child) for child in attribute):
        return not any(child.tag in CONDITIONAL_CONFORMANCE for child in attribute)
    for child in attribute:
        if child.tag != "otherwiseConform":
            continue
        first = next(iter(child), None)
        if first is not None and first.tag == "mandatoryConform" and len(first) == 1:
            return _revision_only_condition(first[0], revision)
    return False


def load_xml_clusters(xml_root: Path) -> dict[int, XmlCluster]:
    """Read Matter 1.6 canonical data_model or generated ZAP cluster XML."""
    if not xml_root.is_dir():
        raise ValueError(f"XML directory does not exist: {xml_root}")
    files = sorted(xml_root.glob("*.xml"))
    if not files:
        raise ValueError(f"No XML files found in {xml_root}")
    clusters: dict[int, XmlCluster] = {}
    for path in files:
        root = ET.parse(path).getroot()
        if root.tag == "cluster":
            revision = int(root.get("revision")) if root.get("revision") else None
            direct_id = root.get("id")
            definitions = (
                [(int(direct_id, 0), root.get("name") or path.stem)] if direct_id
                else [
                    (int(node.get("id"), 0), node.get("name") or root.get("name") or path.stem)
                    for node in root.findall("./clusterIds/clusterId") if node.get("id")
                ]
            )
            required = frozenset(
                int(attribute.get("id"), 0)
                for attribute in root.findall("./attributes/attribute")
                if attribute.get("id") and _canonical_mandatory(attribute, revision)
            )
            for cluster_id, name in definitions:
                if cluster_id > 0x7FFF:
                    continue
                if cluster_id in clusters:
                    raise ValueError(f"Duplicate XML cluster 0x{cluster_id:04X}: {path}")
                clusters[cluster_id] = XmlCluster(cluster_id, name, revision, required, path.name)
            continue
        if root.tag != "configurator":
            raise ValueError(f"Unsupported XML root element {root.tag!r}: {path}")
        for element in root.findall(".//cluster"):
            code = element.findtext("code")
            name = element.findtext("name")
            if code is None or name is None:
                continue  # Struct references and abstract cluster templates.
            cluster_id = int(code, 0)
            if cluster_id > 0x7FFF:
                continue  # Vendor and test clusters are outside the standard range.
            if cluster_id in clusters:
                raise ValueError(f"Duplicate XML cluster 0x{cluster_id:04X}: {path}")
            revisions = [
                int(attribute.get("value", ""), 0)
                for attribute in element.findall("globalAttribute")
                if int(attribute.get("code", "-1"), 0) == 0xFFFD
            ]
            if len(revisions) > 1:
                raise ValueError(f"Multiple revisions for cluster 0x{cluster_id:04X}: {path}")
            required = frozenset(
                int(attribute.get("code", ""), 0)
                for attribute in element.findall("attribute")
                if attribute.get("side") in ("server", "either")
                and _unconditional_mandatory(attribute)
            )
            clusters[cluster_id] = XmlCluster(
                cluster_id, name.strip(), revisions[0] if revisions else None,
                required, path.name,
            )
    return clusters


def load_crystal_clusters(crystal_root: Path) -> dict[int, CrystalCluster]:
    """Read literal and simple same-file macro-expanded cluster DSL declarations."""
    if not crystal_root.is_dir():
        raise ValueError(f"Crystal cluster directory does not exist: {crystal_root}")
    clusters: dict[int, CrystalCluster] = {}
    for path in sorted(crystal_root.glob("*.cr")):
        source = path.read_text(encoding="utf-8")
        for declaration_source in declaration_sources(source):
            declarations = CLUSTER_DECLARATION.findall(declaration_source)
            if not declarations:
                continue
            if len(declarations) > 1:
                raise ValueError(f"Multiple cluster declarations in {path}")
            code, revision = declarations[0]
            cluster_id = int(code, 0)
            if cluster_id in clusters:
                raise ValueError(f"Duplicate Crystal cluster 0x{cluster_id:04X}: {path}")
            attributes = set()
            optional_attributes = set()
            lines = declaration_source.splitlines()
            for index, line in enumerate(lines):
                match = ATTRIBUTE_DECLARATION.match(line)
                if match is None:
                    continue
                attribute_id = int(match.group(1), 0)
                attributes.add(attribute_id)
                declaration = line
                while declaration.rstrip().endswith(",") and index + 1 < len(lines):
                    index += 1
                    declaration = lines[index]
                    if OPTIONAL_LITERAL.search(declaration):
                        optional_attributes.add(attribute_id)
                if OPTIONAL_LITERAL.search(line):
                    optional_attributes.add(attribute_id)
            clusters[cluster_id] = CrystalCluster(
                cluster_id, int(revision), frozenset(attributes),
                frozenset(optional_attributes), path.name,
            )
    return clusters


def build_report(
    xml_clusters: dict[int, XmlCluster], crystal_clusters: dict[int, CrystalCluster]
) -> CoverageReport:
    entries = {
        cluster_id: CoverageEntry(xml, crystal_clusters.get(cluster_id))
        for cluster_id, xml in sorted(xml_clusters.items())
    }
    return CoverageReport(entries, frozenset(crystal_clusters.keys() - xml_clusters.keys()))


def source_digest(xml_root: Path) -> str:
    """Digest filenames and bytes so a regenerated report names its exact input."""
    digest = hashlib.sha256()
    for path in sorted(xml_root.glob("*.xml")):
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def _ids(ids: frozenset[int]) -> str:
    return ", ".join(f"0x{value:04X}" for value in sorted(ids)) or "—"


def load_review_notes(path: Path) -> dict[int, str]:
    """Load maintained qualitative notes separately from measured declarations."""
    def unique_pairs(pairs: list[tuple[str, str]]) -> dict[str, str]:
        values = {}
        for key, value in pairs:
            if key in values:
                raise ValueError(f"Duplicate review note ID {key}: {path}")
            values[key] = value
        return values

    raw = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_pairs)
    if not isinstance(raw, dict):
        raise ValueError(f"Review notes must be a JSON object: {path}")
    notes = {}
    for key, value in raw.items():
        if not re.fullmatch(r"0x[0-9A-F]{4}", key):
            raise ValueError(f"Invalid review note ID {key!r}: {path}")
        if not isinstance(value, str) or not value.strip() or "|" in value or "\n" in value:
            raise ValueError(f"Invalid review note for {key}: {path}")
        notes[int(key, 16)] = value
    return notes


def render_markdown(
    report: CoverageReport, source_count: int, source_digest: str,
    review_notes: dict[int, str] | None = None,
) -> str:
    review_notes = review_notes or {}
    entries = list(report.entries.values())
    present = [entry for entry in entries if entry.implemented]
    matching = sum(entry.revision_matches is True for entry in present)
    unknown_revisions = sum(entry.xml.revision is None for entry in entries)
    missing_attrs = [
        entry for entry in present
        if entry.missing_attributes or entry.optional_mandatory_attributes
    ]
    lines = [
        "# Matter 1.6 cluster declaration coverage",
        "",
        "This is **declaration coverage**. It compares standard cluster IDs, declared",
        "revisions, and only unconditional mandatory server attribute IDs in Matter",
        "1.6 canonical or generated ZAP XML with Crystal cluster DSL declarations.",
        "It does not verify types, feature-dependent requirements, commands, events,",
        "behavior, interoperability,",
        "or certification. A matching row is not a completeness claim.",
        "The qualitative review notes are maintained in",
        "[`protocol-coverage-notes.json`](protocol-coverage-notes.json); they are not",
        "verified by this declaration scan.",
        "",
        "See [server command and event declaration audit](protocol-command-event-coverage.md)",
        "for a separate comparison of literal command and event IDs.",
        "",
        f"XML input: {source_count} files; XML tree SHA-256 `{source_digest}`.",
        "",
        f"- Standard XML clusters: {len(entries)}",
        f"- Crystal declarations for those IDs: {len(present)}",
        f"- Matching known revisions: {matching}",
        f"- Clusters with mandatory attributes absent or optional in Crystal: {len(missing_attrs)}",
        f"- XML clusters with unknown revision: {unknown_revisions}",
        f"- Crystal IDs absent from the XML input: {len(report.crystal_only)}"
        f"{f' ({_ids(report.crystal_only)})' if report.crystal_only else ''}",
        "",
        "| Cluster ID | XML name | XML rev | Crystal rev | Mandatory attrs absent / Crystal-optional | Review notes |",
        "| --- | --- | ---: | ---: | --- | --- |",
    ]
    for entry in entries:
        xml = entry.xml
        crystal = entry.crystal
        gaps = _ids(entry.missing_attributes) if crystal is not None else "cluster absent"
        if entry.optional_mandatory_attributes:
            optional = ", ".join(
                f"0x{value:04X} (optional)"
                for value in sorted(entry.optional_mandatory_attributes)
            )
            gaps = optional if gaps == "—" else f"{gaps}, {optional}"
        lines.append(
            f"| 0x{xml.cluster_id:04X} | {xml.name.replace('|', '&#124;')} | "
            f"{xml.revision if xml.revision is not None else '?'} | "
            f"{crystal.revision if crystal is not None else '—'} | "
            f"{gaps} | {review_notes.get(xml.cluster_id, '—')} |"
        )
    lines += [
        "",
        "Regenerate from the official connectedhomeip `v1.6.0.0` tag:",
        "",
        "```sh",
        "git clone --depth 1 --branch v1.6.0.0 https://github.com/project-chip/connectedhomeip.git /tmp/connectedhomeip-1.6",
        "python3 scripts/protocol_coverage.py \\",
        "  --xml-root /tmp/connectedhomeip-1.6/data_model/1.6/clusters \\",
        "  --crystal-root src/matter/cluster --output docs/protocol-coverage.md",
        "python3 -m unittest discover -s scripts -p 'test_protocol_coverage.py'",
        "```",
        "",
        "The committed report uses the canonical Matter 1.6 data model XML. The",
        "script also accepts the generated ZAP XML tree with its separate schema;",
        "the counts can differ because the generated tree expands templates.",
        "This report intentionally excludes vendor/test IDs above 0x7FFF and abstract",
        "templates without a cluster ID. It counts only attributes directly declared",
        "in each canonical XML file with unconditional mandatory conformance; it",
        "does not resolve inherited attributes. XML attributes marked optional or whose",
        "mandatory conformance has a feature condition are excluded. Simple current",
        "revision thresholds are evaluated against the XML cluster revision. Crystal declarations",
        "with `optional: true` count as a gap for unconditional mandatory XML",
        "attributes even when the attribute ID is present.",
        "Crystal parsing recognizes literal DSL declarations and simple same-file cluster",
        "macros instantiated with literal arguments in `src/matter/cluster/*.cr`.",
        "Other generated declarations, dynamically computed attributes, and runtime",
        "feature gating require separate review.",
        "Edit `docs/protocol-coverage-notes.json` to maintain the separate qualitative",
        "notes; regeneration preserves them.",
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xml-root", required=True, type=Path)
    parser.add_argument("--crystal-root", default=Path("src/matter/cluster"), type=Path)
    parser.add_argument("--output", type=Path, help="Write report to this file; default stdout")
    parser.add_argument("--notes", default=DEFAULT_NOTES, type=Path,
                        help="Qualitative review notes JSON (default: repository docs)")
    arguments = parser.parse_args(argv)
    try:
        report = build_report(
            load_xml_clusters(arguments.xml_root),
            load_crystal_clusters(arguments.crystal_root),
        )
        notes = load_review_notes(arguments.notes)
        output = render_markdown(
            report, source_count=len(list(arguments.xml_root.glob("*.xml"))),
            source_digest=source_digest(arguments.xml_root),
            review_notes=notes,
        )
    except (ValueError, json.JSONDecodeError, ET.ParseError, OSError) as error:
        parser.error(str(error))
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
