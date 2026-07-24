#!/usr/bin/env python3
"""
Validate consistency across three parallel rule-encoding formats:
1. skills/*/SKILL.md (full Claude Code skills)
2. .cursor/rules/*.mdc (Cursor rules)
3. .github/copilot-instructions.md (condensed Copilot instructions)

This script detects drift by checking for discrepancies in code examples,
hard thresholds, and detailed explanations across the three formats.
"""

import re
from pathlib import Path
from typing import Dict, List



class RuleFormat:
    """Represents one of the three rule formats."""

    def __init__(self, name: str, content: str):
        self.name = name
        self.content = content
        self.code_blocks = self._count_code_blocks()
        self.has_detailed = self._has_detailed_explanations()
        self.hard_thresholds = self._find_hard_thresholds()

    def _count_code_blocks(self) -> int:
        """Count the number of ```csharp code blocks in content."""
        return self.content.count('```csharp')

    def _has_detailed_explanations(self) -> bool:
        """Check if content has detailed explanations."""
        # Count lines that are not empty and not just markdown headers
        non_empty_lines = [line for line in self.content.split('\n') if line.strip()]

        # Remove markdown headers and code block markers
        meaningful_lines = []
        for line in non_empty_lines:
            stripped = line.strip()
            if (not stripped.startswith('#') and
                not stripped.startswith('---') and
                not stripped.startswith('```') and
                not stripped.startswith('//') and
                not stripped.startswith('name:') and
                not stripped.startswith('description:') and
                not stripped.startswith('glob') and
                not stripped.startswith('alwaysApply:')):
                meaningful_lines.append(line)

        # If we have more than 15 meaningful lines, it's likely detailed
        return len(meaningful_lines) > 15

    def _find_hard_thresholds(self) -> List[str]:
        """Find hard thresholds in the content."""
        thresholds = []
        content = self.content

        # Look for patterns like "two or more", "two-three", "2-3", etc.
        patterns = [
            r'\b[Oo]ne\s+or\s+more\b',
            r'\b[Tt]wo\s+or\s+more\b',
            r'\b[Tt]wo\s+-\s*three\b',
            r'\b2\s*-\s*3\b',
            r'\b[Oo]ne\s+use\s+case\b',
            r'\b[Oo]ne\s+commit\b',
            r'\b[Ee]xplicit\s+CancellationToken\b',
            r'\b[Cc]onfigureAwait\(false\)\b',
            r'\b[Ii]nvariantCulture\b',
            r'\b[Rr]equired\s+columns\b',
            r'\b[Dd]ropColumn/DropTable/AlterColumn\b',
            r'\b[Rr]enameColumn\b',
            r'\b[Ee]nableRetryOnFailure\b',
            r'\b[Cc]reateExecutionStrategy\b',
            r'\b[Ff]rozenDictionary/FrozenSet\b',
            r'\b[Ii]AsyncDisposable\b',
            r'\b[Pp]eriodicTimer\b',
            r'\b[Bb]ounded\s+Channel\b',
            r'\b[Pp]arallel\.ForEachAsync\b',
            r'\b[Jj]sonStringEnumConverter\b',
            r'\b[Rr]eferenceHandler\.Preserve\b',
        ]

        for pattern in patterns:
            matches = re.findall(pattern, content)
            if matches:
                thresholds.extend(matches)

        # Look for exception types
        exception_patterns = [
            r'OperationCanceledException',
            r'DbUpdateConcurrencyException',
            r'JsonException',
            r'ArgumentNullException',
            r'ArgumentException',
            r'InvalidOperationException',
            r'ObjectDisposedException',
            r'InvalidCastException',
            r'NotSupportedException',
            r'NotImplementedException',
        ]

        for pattern in exception_patterns:
            if re.search(pattern, content):
                thresholds.append(pattern)

        return list(set(thresholds))


def extract_copilot_section(skill_name: str) -> RuleFormat:
    """Extract the section for this skill from copilot-instructions.md."""
    copilot_path = Path(".github/copilot-instructions.md")
    if not copilot_path.exists():
        return RuleFormat("copilot", "")

    content = copilot_path.read_text(encoding='utf-8')

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
    if not category:
        return RuleFormat("copilot", "")

    # Find the section
    lines = content.split('\n')
    in_section = False
    section_lines = []

    for line in lines:
        if line.startswith(f"## {category}"):
            in_section = True
            continue
        elif in_section:
            if line.startswith('## ') and line[3:].strip() not in ['.NET Senior Engineering Rules', '']:
                # Reached next category
                break
            section_lines.append(line)

    # Create virtual file content
    virtual_content = f"# {category}\n\n" + '\n'.join(section_lines)

    return RuleFormat("copilot", virtual_content)


def validate_skill(skill_name: str) -> Dict:
    """Validate consistency of a single skill across all three formats."""
    results = {
        "skill": skill_name,
        "issues": [],
        "formats": {}
    }

    # Load SKILL.md
    skill_file = Path("skills") / skill_name / "SKILL.md"
    if skill_file.exists():
        skill_content = skill_file.read_text(encoding='utf-8')
        results["formats"]["SKILL.md"] = RuleFormat("SKILL.md", skill_content)
    else:
        results["issues"].append("SKILL.md not found")
        return results

    # Load .mdc
    mdc_file = Path(".cursor/rules") / f"{skill_name}.mdc"
    if mdc_file.exists():
        mdc_content = mdc_file.read_text(encoding='utf-8')
        results["formats"]["mdc"] = RuleFormat("mdc", mdc_content)
    else:
        results["issues"].append(".mdc file not found")

    # Load copilot section
    results["formats"]["copilot"] = extract_copilot_section(skill_name)

    # Check for missing formats
    if "mdc" not in results["formats"] or not results["formats"]["mdc"].content:
        results["issues"].append("Missing .mdc format")

    # Compare code examples
    sk_blocks = results["formats"]["SKILL.md"].code_blocks
    mdc_blocks = results["formats"]["mdc"].code_blocks if "mdc" in results["formats"] else 0
    copilot_blocks = results["formats"]["copilot"].code_blocks

    if sk_blocks != mdc_blocks:
        results["issues"].append(
            f"Code example count mismatch: SKILL.md has {sk_blocks}, .mdc has {mdc_blocks}"
        )

    if sk_blocks != copilot_blocks:
        results["issues"].append(
            f"Code example count mismatch: SKILL.md has {sk_blocks}, copilot has {copilot_blocks}"
        )

    # Compare detailed explanations
    sk_detailed = results["formats"]["SKILL.md"].has_detailed
    mdc_detailed = results["formats"]["mdc"].has_detailed if "mdc" in results["formats"] else False
    copilot_detailed = results["formats"]["copilot"].has_detailed

    if sk_detailed != mdc_detailed:
        results["issues"].append(
            f"Detailed explanation mismatch: SKILL.md has {sk_detailed}, .mdc has {mdc_detailed}"
        )

    if sk_detailed != copilot_detailed:
        results["issues"].append(
            f"Detailed explanation mismatch: SKILL.md has {sk_detailed}, copilot has {copilot_detailed}"
        )

    # Check for hard thresholds present in only one format
    all_thresholds = set()
    for format_name in ["SKILL.md", "mdc", "copilot"]:
        if format_name in results["formats"]:
            for threshold in results["formats"][format_name].hard_thresholds:
                all_thresholds.add(threshold)

    for threshold in all_thresholds:
        formats_with_threshold = []
        for format_name in ["SKILL.md", "mdc", "copilot"]:
            if format_name in results["formats"] and threshold in results["formats"][format_name].hard_thresholds:
                formats_with_threshold.append(format_name)

        if len(formats_with_threshold) < 2:
            results["issues"].append(
                f"Hard threshold/exception '{threshold}' present in only {', '.join(formats_with_threshold)}"
            )

    return results


def print_reconciliation_help(results: Dict):
    """Print helpful reconciliation advice for a skill with issues."""
    skill_name = results["skill"]
    issues = results["issues"]
    formats = results["formats"]

    print("\n🔧 RECONCILIATION GUIDANCE")
    print("-" * 80)

    # Code example issues
    sk_blocks = formats["SKILL.md"].code_blocks
    mdc_blocks = formats.get("mdc", RuleFormat("mdc", "")).code_blocks
    copilot_blocks = formats["copilot"].code_blocks

    if sk_blocks != mdc_blocks:
        print(f"\n⚠️  .mdc file needs updating:")
        print(f"   SKILL.md has {sk_blocks} code blocks, .mdc has {mdc_blocks}")
        print(f"   Action: Copy code examples from SKILL.md to .cursor/rules/{skill_name}.mdc")

    if sk_blocks != copilot_blocks:
        print(f"\n⚠️  copilot-instructions.md needs updating:")
        print(f"   SKILL.md has {sk_blocks} code blocks, copilot has {copilot_blocks}")
        print(f"   Action: Add condensed rule statements to .github/copilot-instructions.md")
        print(f"   Tip: Preserve hard thresholds like '2-3 attempts', 'one use case', etc.")

    # Hard threshold issues
    all_thresholds = set()
    for format_name in ["SKILL.md", "mdc", "copilot"]:
        if format_name in formats:
            for threshold in formats[format_name].hard_thresholds:
                all_thresholds.add(threshold)

    for threshold in all_thresholds:
        formats_with_threshold = []
        for format_name in ["SKILL.md", "mdc", "copilot"]:
            if format_name in formats and threshold in formats[format_name].hard_thresholds:
                formats_with_threshold.append(format_name)

        if len(formats_with_threshold) < 2:
            present_in = ', '.join(formats_with_threshold) if formats_with_threshold else 'none'
            print(f"\n⚠️  Hard threshold/exception '{threshold}' exists in only {present_in}")
            print(f"   Action: Ensure '{threshold}' is mentioned in all three formats")

    print("\n📋 QUICK FIX COMMANDS:")
    print(f"  1. Update .mdc file:")
    print(f"     cp skills/{skill_name}/SKILL.md .cursor/rules/{skill_name}.mdc")
    print(f"\n  2. Update copilot section:")
    print(f"     vim .github/copilot-instructions.md")
    print(f"     # Add condensed version under appropriate category header")
    print(f"\n  3. Verify fix:")
    print(f"     python3 validate_rule_consistency.py")


def main():
    """Main validation function."""
    print("=" * 80)
    print("Rule Format Consistency Check")
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

    all_skills = []
    issues_found = 0

    for skill_name in skills_to_check:
        print(f"\nChecking skill: {skill_name}")
        print("-" * 80)

        results = validate_skill(skill_name)
        all_skills.append(results)

        if results["issues"]:
            print(f" ⚠️ Issues found:")
            for issue in results["issues"]:
                print(f" - {issue}")
            issues_found += 1
            print_reconciliation_help(results)
        else:
            print(f" ✓ No consistency issues detected")

    print()
    print("=" * 80)
    print("Summary")
    print("=" * 80)

    total_skills = len(skills_to_check)
    skills_with_issues = sum(1 for s in all_skills if s["issues"])

    print(f"Total skills checked: {total_skills}")
    print(f"Skills with issues: {skills_with_issues}")
    print(f"Total issues found: {issues_found}")
    print()

    if issues_found > 0:
        print("❌ Consistency issues detected!")
        print("\nThis script helps identify drift between:")
        print(" 1. Full SKILL.md files (skills/*/SKILL.md)")
        print(" 2. Cursor .mdc rules (.cursor/rules/*.mdc)")
        print(" 3. Condensed Copilot instructions (.github/copilot-instructions.md)")
        print("\nCommon issues to check:")
        print(" - Code examples present in SKILL.md but missing in .mdc or copilot")
        print(" - Hard thresholds (e.g., 'two or more') mentioned in one format only")
        print(" - Exception types mentioned in one format but not others")
        print(" - Detailed explanations condensed in copilot vs full in SKILL.md")
        print("\n💡 Tip: Run 'python3 reconcile_rules.py report' for detailed analysis")
        print("💡 Tip: Run 'python3 reconcile_rules.py checklist' for manual review guidance")
        return 1
    else:
        print("✅ All skills are consistent across formats!")
        return 0


if __name__ == "__main__":
    exit(main())
