#!/usr/bin/env python3
"""
Reconcile drift across three parallel rule-encoding formats.

This script helps maintain consistency by:
1. Identifying discrepancies between formats
2. Providing a checklist for manual review
3. Generating consistency reports
4. Helping update all formats when one is changed

Usage:
  python3 reconcile_rules.py check   - Check consistency (same as validate_rule_consistency.py)
  python3 reconcile_rules.py report  - Generate detailed consistency report
  python3 reconcile_rules.py checklist - Generate a manual review checklist
"""

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List


def validate_skills_directory():
    """Return whether the skills directory is available for processing."""
    skills_directory = Path("skills")
    if not skills_directory.is_dir():
        print("Error: skills/ directory does not exist.", file=sys.stderr)
        return False

    try:
        next(skills_directory.iterdir())
    except StopIteration:
        print("Error: skills/ directory is empty.", file=sys.stderr)
        return False
    except OSError as error:
        print(f"Error: cannot inspect skills/ directory: {error}", file=sys.stderr)
        return False

    return True


def read_text_file(path):
    """Read a UTF-8 file, reporting failures without ending the run."""
    try:
        return path.read_text(encoding='utf-8')
    except (OSError, UnicodeError) as error:
        print(f"Warning: could not read {path}: {error}", file=sys.stderr)
        return None


def has_frontmatter(content, path):
    """Return whether content starts with a complete frontmatter block."""
    frontmatter = re.match(r"\A---\s*\n.*?\n---\s*(?:\n|$)", content, re.DOTALL)
    if frontmatter is None:
        print(f"Warning: no frontmatter found in {path}; skipping.", file=sys.stderr)
        return False
    return True


def run_consistency_check():
    """Run the consistency check and return results."""
    result = subprocess.run(
        ["python3", "validate_rule_consistency.py"],
        capture_output=True,
        text=True
    )
    return result.returncode, result.stdout, result.stderr


def generate_detailed_report():
    """Generate a detailed consistency report."""
    print("=" * 80)
    print("Detailed Rule Format Consistency Report")
    print("=" * 80)
    print()

    # List of the 13 skills to check
    skills_to_check = [
        "serialization-review",
        "http-resilience-and-outbound-calls",
        "middleware-and-pipeline-order",
        "domain-modeling-and-primitives",
        "ef-core-transactions-and-concurrency",
        "concurrency-and-shared-state",
        "background-work-and-hosted-services",
        "logging-and-observability",
        "memory-leaks-and-diagnostics",
        "datetime-and-time-handling",
        "disposal-and-resource-lifetime",
        "globalization-and-culture",
        "collections-and-equality"
    ]

    report = {
        "timestamp": "2026-07-26",
        "skills": {}
    }

    for skill_name in skills_to_check:
        print(f"\nSkill: {skill_name}")
        print("-" * 80)

        skill_report = {
            "skill_name": skill_name,
            "formats": {},
            "issues": []
        }

        # Check SKILL.md
        skill_file = Path("skills") / skill_name / "SKILL.md"
        if skill_file.exists():
            content = read_text_file(skill_file)
            if content is not None and has_frontmatter(content, skill_file):
                code_blocks = content.count('```csharp')
                lines = [l for l in content.split('\n') if l.strip()]
                meaningful_lines = [l for l in lines if not l.startswith('#') and not l.startswith('---')]

                skill_report["formats"]["SKILL.md"] = {
                    "exists": True,
                    "code_blocks": code_blocks,
                    "line_count": len(lines),
                    "meaningful_line_count": len(meaningful_lines),
                    "size_bytes": len(content)
                }
                print(f"  SKILL.md: {code_blocks} code blocks, {len(meaningful_lines)} meaningful lines")
        else:
            skill_report["issues"].append("SKILL.md not found")
            print(f"  SKILL.md: NOT FOUND")

        # Check .mdc
        mdc_file = Path(".cursor/rules") / f"{skill_name}.mdc"
        if mdc_file.exists():
            content = read_text_file(mdc_file)
            if content is not None and has_frontmatter(content, mdc_file):
                code_blocks = content.count('```csharp')
                lines = [l for l in content.split('\n') if l.strip()]
                meaningful_lines = [l for l in lines if not l.startswith('#') and not l.startswith('---')]

                skill_report["formats"]["mdc"] = {
                    "exists": True,
                    "code_blocks": code_blocks,
                    "line_count": len(lines),
                    "meaningful_line_count": len(meaningful_lines),
                    "size_bytes": len(content)
                }
                print(f"  .mdc: {code_blocks} code blocks, {len(meaningful_lines)} meaningful lines")
        else:
            skill_report["issues"].append(".mdc file not found")
            print(f"  .mdc: NOT FOUND")

        # Check copilot section
        copilot_path = Path(".github/copilot-instructions.md")
        if copilot_path.exists():
            content = read_text_file(copilot_path)
            if content is None:
                report["skills"][skill_name] = skill_report
                continue
            # Map skill names to copilot categories
            skill_to_category = {
                "serialization-review": "Serialization",
                "http-resilience-and-outbound-calls": "HTTP",
                "middleware-and-pipeline-order": "Pipeline order",
                "domain-modeling-and-primitives": "Domain modeling",
                "ef-core-transactions-and-concurrency": "EF transactions and concurrency",
                "concurrency-and-shared-state": "Concurrency",
                "background-work-and-hosted-services": "Background Work",
                "logging-and-observability": "Logging",
                "memory-leaks-and-diagnostics": "Memory",
                "datetime-and-time-handling": "Time",
                "disposal-and-resource-lifetime": "Disposal",
                "globalization-and-culture": "Culture",
                "collections-and-equality": "Collections"
            }

            category = skill_to_category.get(skill_name)
            if category:
                lines = content.split('\n')
                in_section = False
                section_lines = []
                for line in lines:
                    if line.startswith(f"## {category}"):
                        in_section = True
                        continue
                    elif in_section:
                        if line.startswith('## ') and line[3:].strip() not in ['.NET Senior Engineering Rules', '']:
                            break
                        section_lines.append(line)

                copilot_content = '\n'.join(section_lines)
                code_blocks = copilot_content.count('```csharp')
                lines_count = len(section_lines)
                meaningful_lines = [l for l in section_lines if l.strip() and not l.startswith('#')]

                skill_report["formats"]["copilot"] = {
                    "exists": True,
                    "code_blocks": code_blocks,
                    "line_count": lines_count,
                    "meaningful_line_count": len(meaningful_lines),
                    "size_bytes": len(copilot_content)
                }
                print(f"  copilot: {code_blocks} code blocks, {len(meaningful_lines)} meaningful lines")
            else:
                skill_report["issues"].append("Copilot category not found")
                print(f"  copilot: CATEGORY NOT FOUND")
        else:
            skill_report["issues"].append("copilot-instructions.md not found")
            print(f"  copilot: NOT FOUND")

        report["skills"][skill_name] = skill_report

    print()
    print("=" * 80)
    print("Summary Statistics")
    print("=" * 80)

    total_code_blocks_sk = sum(s["formats"].get("SKILL.md", {}).get("code_blocks", 0)
                            for s in report["skills"].values())
    total_code_blocks_mdc = sum(s["formats"].get("mdc", {}).get("code_blocks", 0)
                              for s in report["skills"].values())
    total_code_blocks_copilot = sum(s["formats"].get("copilot", {}).get("code_blocks", 0)
                                   for s in report["skills"].values())

    print(f"Total code blocks across all skills:")
    print(f"  SKILL.md: {total_code_blocks_sk}")
    print(f"  .mdc: {total_code_blocks_mdc}")
    print(f"  copilot: {total_code_blocks_copilot}")
    print()

    # Save report to JSON
    report_file = Path("rule_consistency_report.json")
    report_file.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(f"✓ Detailed report saved to: {report_file}")

    return report


def generate_checklist():
    """Generate a manual review checklist."""
    print("=" * 80)
    print("Manual Review Checklist for Rule Consistency")
    print("=" * 80)
    print()
    print("This checklist helps ensure all three formats stay in sync when making changes.")
    print()

    print("BEFORE MAKING CHANGES:")
    print("-" * 80)
    print("✓ Run: python3 validate_rule_consistency.py")
    print("✓ Review the consistency report: rule_consistency_report.json")
    print()

    print("WHEN ADDING/CHANGING A RULE:")
    print("-" * 80)
    print("1. Update the SKILL.md file (skills/<skill>/SKILL.md)")
    print("   - Add comprehensive explanations")
    print("   - Include code examples with BEFORE/AFTER patterns")
    print("   - Document hard thresholds and exception types")
    print()
    print("2. Update the .mdc file (.cursor/rules/<skill>.mdc)")
    print("   - Mirror the same content from SKILL.md")
    print("   - Keep the same structure and examples")
    print()
    print("3. Update the copilot-instructions.md file (.github/copilot-instructions.md)")
    print("   - Add a condensed version under the appropriate category header")
    print("   - Keep only the essential rules (remove detailed explanations)")
    print("   - Preserve hard thresholds and exception types")
    print()

    print("AFTER MAKING CHANGES:")
    print("-" * 80)
    print("✓ Run: python3 validate_rule_consistency.py")
    print("✓ Verify all skills show 'No consistency issues detected'")
    print("✓ Commit all three changed files together")
    print()

    print("COMMON PATTERNS TO CHECK:")
    print("-" * 80)
    print("✓ Code examples: SKILL.md has examples, .mdc mirrors them, copilot may omit")
    print("✓ Hard thresholds: All formats should mention the same numbers/limits")
    print("✓ Exception types: All formats should list the same exceptions")
    print("✓ Before/After examples: SKILL.md should have them, .mdc mirrors, copilot may condense")
    print()

    print("EXAMPLE WORKFLOW:")
    print("-" * 80)
    print("# You want to add a new rule about CancellationToken")
    print("cd /home/redrocket/task-factory/workdir/dotnet-senior-skills")
    print()
    print("# 1. Update SKILL.md")
    print("vim skills/background-work-and-hosted-services/SKILL.md")
    print()
    print("# 2. Update .mdc file")
    print("vim .cursor/rules/background-work-and-hosted-services.mdc")
    print()
    print("# 3. Update copilot-instructions.md")
    print("vim .github/copilot-instructions.md")
    print()
    print("# 4. Verify consistency")
    print("python3 validate_rule_consistency.py")
    print()

    print("=" * 80)
    print("Automated Tools Available")
    print("=" * 80)
    print()
    print("1. validate_rule_consistency.py")
    print("   - Quick consistency check")
    print("   - Lists all discrepancies")
    print()
    print("2. reconcile_rules.py report")
    print("   - Detailed consistency report")
    print("   - Saves to rule_consistency_report.json")
    print()
    print("3. reconcile_rules.py checklist")
    print("   - This manual review checklist")
    print()


def main():
    """Main function."""
    if len(sys.argv) < 2:
        print("Usage: python3 reconcile_rules.py <command>")
        print("  check    - Check consistency (default)")
        print("  report   - Generate detailed consistency report")
        print("  checklist - Generate manual review checklist")
        return 1

    if not validate_skills_directory():
        return 2

    command = sys.argv[1]

    if command == "report":
        generate_detailed_report()
        return 0
    elif command == "checklist":
        generate_checklist()
        return 0
    else:  # default to check
        print("Running consistency check...")
        print()
        returncode, stdout, stderr = run_consistency_check()
        print(stdout)
        if stderr:
            print("STDERR:", stderr)
        return returncode


if __name__ == "__main__":
    exit(main())
