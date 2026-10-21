#!/usr/bin/env python3
"""Compare canonical Matter command/event declarations with literal Crystal DSL IDs.

This intentionally does not evaluate feature combinations, inherited members,
command handlers, payloads, event emission, or protocol behavior.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

from protocol_coverage import CLUSTER_DECLARATION, source_digest

MEMBER_DECLARATION = re.compile(r"^\s*(command|event)\s+(0x[0-9a-fA-F]+|\d+)\s*,", re.MULTILINE)
REQUIRES = re.compile(r"\brequires:\s*(\{[^}]*\}|\[[^]]*\]|:[a-zA-Z_][a-zA-Z_0-9]*)")


@dataclass(frozen=True)
class XmlMember:
    member_id: int
    name: str
    requirement: str
    condition: str = ""
    revision_threshold: int | None = None


@dataclass(frozen=True)
class XmlCluster:
    cluster_id: int
    name: str
    revision: int
    commands: dict[int, XmlMember]
    events: dict[int, XmlMember]


@dataclass(frozen=True)
class CrystalCluster:
    cluster_id: int
    revision: int
    commands: dict[int, str]
    events: dict[int, str]


@dataclass(frozen=True)
class CoverageEntry:
    xml: XmlCluster
    crystal: CrystalCluster

    def required(self, kind: str) -> set[int]:
        members = getattr(self.xml, kind)
        return {
            member_id for member_id, member in members.items()
            if member.requirement == "mandatory" or (
                member.revision_threshold is not None
                and self.crystal.revision >= member.revision_threshold
            )
        }

    @property
    def missing_mandatory_commands(self) -> set[int]:
        return self.required("commands") - self.crystal.commands.keys()

    @property
    def missing_mandatory_events(self) -> set[int]:
        return self.required("events") - self.crystal.events.keys()

    @property
    def revision_conditional_commands(self) -> set[int]:
        return {code for code, member in self.xml.commands.items() if member.revision_threshold is not None}

    @property
    def feature_conditional_commands(self) -> set[int]:
        return {
            code for code, member in self.xml.commands.items()
            if member.requirement == "conditional" and member.revision_threshold is None
        }


def _expression(node: ET.Element) -> str:
    if node.tag == "feature":
        return f"feature({node.get('name', '?')})"
    if node.tag == "revision":
        return f"revision({node.get('value', '?')})"
    children = [_expression(child) for child in node]
    if node.tag == "notTerm" and len(children) == 1:
        return f"not({children[0]})"
    if node.tag == "greaterOrEqualTerm" and len(children) == 2:
        return f"{children[0]} >= {children[1]}"
    if node.tag in ("andTerm", "orTerm"):
        operator = " and " if node.tag == "andTerm" else " or "
        return "(" + operator.join(children) + ")"
    return f"{node.tag}({', '.join(children)})"


def _revision_threshold(node: ET.Element) -> int | None:
    if node.tag != "greaterOrEqualTerm":
        return None
    operands = list(node)
    if len(operands) != 2 or any(item.tag != "revision" for item in operands):
        return None
    if operands[0].get("value") != "current":
        return None
    try:
        return int(operands[1].get("value", ""), 0)
    except ValueError:
        return None


def _requirement(node: ET.Element) -> tuple[str, str, int | None]:
    direct = node.find("mandatoryConform")
    if direct is not None:
        if not len(direct):
            return "mandatory", "", None
        if len(direct) == 1:
            expression = direct[0]
            return "conditional", _expression(expression), _revision_threshold(expression)
        return "conditional", ", ".join(_expression(child) for child in direct), None
    alternative = node.find("otherwiseConform")
    if alternative is not None:
        mandatory = alternative.find("mandatoryConform")
        if mandatory is not None and len(mandatory) == 1:
            expression = mandatory[0]
            return "conditional", _expression(expression), _revision_threshold(expression)
        return "conditional", "otherwiseConform", None
    for tag in ("optionalConform", "provisionalConform", "disallowConform"):
        if node.find(tag) is not None:
            return tag.replace("Conform", "").lower(), "", None
    return "unknown", "no explicit conformance", None


def _members(root: ET.Element, kind: str) -> dict[int, XmlMember]:
    result = {}
    for node in root.findall(f"./{kind}/{kind[:-1]}"):
        if kind == "commands" and node.get("direction") != "commandToServer":
            continue
        if not node.get("id"):
            continue
        code = int(node.get("id"), 0)
        if code in result:
            raise ValueError(f"Duplicate {kind} ID 0x{code:04X}")
        requirement, condition, threshold = _requirement(node)
        result[code] = XmlMember(code, node.get("name", "?"), requirement, condition, threshold)
    return result


def load_xml_members(xml_root: Path) -> dict[int, XmlCluster]:
    if not xml_root.is_dir():
        raise ValueError(f"XML directory does not exist: {xml_root}")
    paths = sorted(xml_root.glob("*.xml"))
    if not paths:
        raise ValueError(f"No XML files in {xml_root}")
    clusters = {}
    for path in paths:
        root = ET.parse(path).getroot()
        if root.tag != "cluster":
            raise ValueError(f"Expected canonical cluster XML: {path}")
        code_text = root.get("id")
        definitions = (
            [(int(code_text, 0), root.get("name", path.stem))] if code_text else
            [(int(item.get("id"), 0), item.get("name", root.get("name", path.stem)))
             for item in root.findall("./clusterIds/clusterId") if item.get("id")]
        )
        revision_text = root.get("revision")
        if not revision_text:
            continue  # A revision comparison cannot be made.
        for code, name in definitions:
            if code > 0x7FFF:
                continue
            if code in clusters:
                raise ValueError(f"Duplicate cluster ID 0x{code:04X}: {path}")
            clusters[code] = XmlCluster(
                code, name, int(revision_text, 0),
                _members(root, "commands"), _members(root, "events"),
            )
    return clusters


def load_crystal_members(crystal_root: Path) -> dict[int, CrystalCluster]:
    if not crystal_root.is_dir():
        raise ValueError(f"Crystal directory does not exist: {crystal_root}")
    clusters = {}
    for path in sorted(crystal_root.glob("*.cr")):
        source = path.read_text(encoding="utf-8")
        declarations = CLUSTER_DECLARATION.findall(source)
        if not declarations:
            continue
        if len(declarations) != 1:
            raise ValueError(f"Multiple cluster declarations: {path}")
        code, revision = declarations[0]
        cluster_id = int(code, 0)
        if cluster_id in clusters:
            raise ValueError(f"Duplicate Crystal cluster 0x{cluster_id:04X}: {path}")
        commands, events = {}, {}
        for match in MEMBER_DECLARATION.finditer(source):
            kind, member_code = match.groups()
            destination = commands if kind == "command" else events
            member_id = int(member_code, 0)
            if member_id in destination:
                raise ValueError(f"Duplicate {kind} ID 0x{member_id:04X}: {path}")
            end = source.find("\n", match.end())
            line = source[match.start():end if end >= 0 else len(source)]
            requires = REQUIRES.search(line)
            destination[member_id] = requires.group(1) if requires else "—"
        clusters[cluster_id] = CrystalCluster(cluster_id, int(revision), commands, events)
    return clusters


def build_report(xml: dict[int, XmlCluster], crystal: dict[int, CrystalCluster]) -> dict[int, CoverageEntry]:
    return {
        code: CoverageEntry(xml[code], implementation)
        for code, implementation in sorted(crystal.items()) if code in xml
    }


def _ids(values: set[int]) -> str:
    return ", ".join(f"0x{code:04X}" for code in sorted(values)) or "—"


def render_markdown(report: dict[int, CoverageEntry], source_count: int, source_digest: str) -> str:
    entries = list(report.values())
    missing_commands = sum(len(entry.missing_mandatory_commands) for entry in entries)
    missing_events = sum(len(entry.missing_mandatory_events) for entry in entries)
    conditional = [
        (entry, kind, member)
        for entry in entries for kind in ("commands", "events")
        for member in getattr(entry.xml, kind).values()
        if member.requirement == "conditional"
    ]
    lines = [
        "# Matter 1.6 server command and event declaration audit", "",
        "This compares canonical Matter XML IDs with literal Crystal cluster DSL declarations",
        "for implemented standard clusters. A declared ID does not prove a working handler,",
        "correct payload, event emission, feature gating, or interoperability. This is not a completeness claim.",
        "Feature and complex conditions are displayed for manual review, not evaluated.", "",
        f"XML input: {source_count} files; XML tree SHA-256 `{source_digest}`.", "",
        f"- Implemented standard cluster IDs compared: {len(entries)}",
        f"- Direct or revision-active mandatory server command IDs absent: {missing_commands}",
        f"- Direct or revision-active mandatory event IDs absent: {missing_events}",
        f"- Conditional command/event declarations for review: {len(conditional)}", "",
        "| Cluster ID | XML name | XML rev | Crystal rev | Mandatory server commands absent | Mandatory events absent |",
        "| --- | --- | ---: | ---: | --- | --- |",
    ]
    for entry in entries:
        lines.append(
            f"| 0x{entry.xml.cluster_id:04X} | {entry.xml.name.replace('|', '&#124;')} | "
            f"{entry.xml.revision} | {entry.crystal.revision} | "
            f"{_ids(entry.missing_mandatory_commands)} | {_ids(entry.missing_mandatory_events)} |"
        )
    lines += [
        "", "## Conditional requirements requiring review", "",
        "A revision-only threshold counts as mandatory above its threshold at the",
        "advertised Crystal revision. Feature and mixed conditions are left unresolved.",
        "Crystal `requires:` is shown verbatim where a literal DSL declaration provides it.", "",
        "| Cluster ID | Kind | ID | XML condition | Crystal declaration |",
        "| --- | --- | ---: | --- | --- |",
    ]
    for entry, kind, member in conditional:
        declared = getattr(entry.crystal, kind).get(member.member_id)
        state = f"declared; requires `{declared}`" if declared is not None else "absent"
        lines.append(
            f"| 0x{entry.xml.cluster_id:04X} | {kind[:-1]} | 0x{member.member_id:04X} | "
            f"{member.condition.replace('|', '&#124;')} | {state} |"
        )
    lines += [
        "", "Regenerate from official connectedhomeip `v1.6.0.0` canonical XML:", "",
        "```sh",
        "python3 scripts/protocol_command_event_coverage.py \\",
        "  --xml-root /tmp/connectedhomeip-1.6/data_model/1.6/clusters \\",
        "  --crystal-root src/matter/cluster --output docs/protocol-command-event-coverage.md",
        "python3 -m unittest discover -s scripts -p 'test_protocol_command_event_coverage.py'",
        "```", "",
        "Only `commandToServer` commands and server events declared directly in the XML",
        "file are compared. Response commands, inherited members, unknown XML roots,",
        "commands without an explicit XML direction, dynamically generated Crystal",
        "declarations, and runtime feature combinations",
        "are outside this report. Revision-only conditions use the Crystal cluster's",
        "advertised revision; all other conditional rows require a separate conformance review.", "",
    ]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xml-root", required=True, type=Path)
    parser.add_argument("--crystal-root", default=Path("src/matter/cluster"), type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        report = build_report(load_xml_members(args.xml_root), load_crystal_members(args.crystal_root))
        result = render_markdown(report, len(list(args.xml_root.glob("*.xml"))), source_digest(args.xml_root))
        if args.output:
            args.output.write_text(result, encoding="utf-8")
        else:
            print(result, end="")
    except (OSError, ValueError, ET.ParseError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
