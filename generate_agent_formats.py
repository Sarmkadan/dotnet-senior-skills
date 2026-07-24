#!/usr/bin/env python3
"""
Generate AGENTS.md and Windsurf/Cline rules from skills directory.

This script serves as a single-source generator that keeps skills/ as canonical
and generates condensed formats for cross-tool compatibility.

Supported formats:
- AGENTS.md: Cross-tool rules format adopted by multiple agents
- .windsurfrules/*.md: Windsurf rules format
- .clinerules/*.md: Cline rules format
"""

import os
import re
import shutil
from pathlib import Path
from typing import Dict, List, Optional


def extract_frontmatter(file_path: Path) -> Dict[str, str]:
    """Extract frontmatter from a SKILL.md file."""
    content = file_path.read_text(encoding='utf-8')

    # Extract frontmatter section
    frontmatter_match = re.match(r'---\n(.*?)---', content, re.DOTALL)
    if not frontmatter_match:
        return {}

    frontmatter = frontmatter_match.group(1)

    # Parse key-value pairs
    fields = {}
    for line in frontmatter.strip().split('\n'):
        if ':' in line:
            key, value = line.split(':', 1)
            fields[key.strip()] = value.strip()

    return fields


def extract_rules_from_skill(skill_file: Path) -> Optional[str]:
    """Extract the rules section from a SKILL.md file."""
    content = skill_file.read_text(encoding='utf-8')

    # Find the first markdown header (##) which indicates the start of rules
    # Everything after "## " is the skill name, then the rules follow
    lines = content.split('\n')

    # Find the first ## line that's not the skill title itself
    # Skip the first ## line if it's the skill name (e.g., "## API Layer Boundaries")
    start_idx = 0
    for i, line in enumerate(lines):
        if line.startswith('## ') and i > 0:
            # This is a rule section
            return '\n'.join(lines[i:])

    return None


def generate_agents_md(skills_dir: Path, output_path: Path) -> bool:
    """Generate AGENTS.md file with condensed rules from all skills."""
    print(f"Generating AGENTS.md at {output_path}")

    # Find all skill directories
    skill_dirs = [d for d in skills_dir.iterdir() if d.is_dir()]

    if not skill_dirs:
        print("ERROR: No skill directories found")
        return False

    # Collect all rules
    all_rules = []

    for skill_dir in sorted(skill_dirs):
        skill_name = skill_dir.name
        skill_file = skill_dir / "SKILL.md"

        if not skill_file.exists():
            continue

        # Extract frontmatter
        frontmatter = extract_frontmatter(skill_file)
        name = frontmatter.get('name', skill_name)
        description = frontmatter.get('description', '')

        # Extract rules
        rules = extract_rules_from_skill(skill_file)

        if rules:
            all_rules.append({
                'name': name,
                'description': description,
                'rules': rules,
                'skill_name': skill_name
            })

    if not all_rules:
        print("ERROR: No valid skill rules found")
        return False

    # Generate AGENTS.md content
    lines = []
    lines.append("# .NET Senior Engineering Rules")
    lines.append("")
    lines.append("Condensed rules for this codebase. Full versions with rationale and examples live in `skills/`.")
    lines.append("")

    # Group rules by category based on skill name prefix
    # e.g., "ef-core-transactions-and-concurrency" -> "EF Core"
    for rule_set in all_rules:
        skill_name = rule_set['skill_name']

        # Extract category from skill name - map specific prefixes to better names
        category_map = {
            'ef': 'EF Core',
            'async': 'Async',
            'di': 'DI',
            'http': 'HTTP',
            'ef-core': 'EF Core',
            'api': 'API',
            'domain': 'Domain',
            'testing': 'Testing',
            'security': 'Security',
            'performance': 'Performance',
            'concurrency': 'Concurrency',
            'disposal': 'Disposal',
            'logging': 'Logging',
            'datetime': 'Date/Time',
            'globalization': 'Globalization',
            'collections': 'Collections',
            'middleware': 'Middleware',
            'nullable': 'Nullability',
            'serialization': 'Serialization',
            'solid': 'SOLID',
            'memory': 'Memory',
            'background': 'Background Work',
            'configuration': 'Configuration',
            'exception': 'Errors',
            'input': 'Input Validation'
        }

        category = category_map.get(skill_name.split('-')[0], skill_name.split('-')[0].title())

        # Add category header if it's different from previous
        if not lines or f"## {category}" not in '\n'.join(lines):
            lines.append("")
            lines.append(f"## {category}")
            lines.append("")

        # Add rules
        lines.append(rule_set['rules'])

    # Write file
    output_path.write_text('\n'.join(lines), encoding='utf-8')
    print(f"✓ Generated AGENTS.md with {len(all_rules)} rule sets")
    return True


def generate_windsurf_rules(skills_dir: Path, output_dir: Path) -> bool:
    """Generate Windsurf .windsurfrules files from skills."""
    print(f"Generating Windsurf rules at {output_dir}")

    # Find all skill directories
    skill_dirs = [d for d in skills_dir.iterdir() if d.is_dir()]

    if not skill_dirs:
        print("ERROR: No skill directories found")
        return False

    # Create output directory
    output_dir.mkdir(parents=True, exist_ok=True)

    generated_files = 0

    for skill_dir in sorted(skill_dirs):
        skill_name = skill_dir.name
        skill_file = skill_dir / "SKILL.md"

        if not skill_file.exists():
            continue

        # Extract frontmatter
        frontmatter = extract_frontmatter(skill_file)
        name = frontmatter.get('name', skill_name)
        description = frontmatter.get('description', '')

        # Extract rules
        rules = extract_rules_from_skill(skill_file)

        if not rules:
            continue

        # Determine output filename
        # Convert skill name to Windsurf rules format
        # e.g., "ef-core-transactions-and-concurrency" -> "ef-core-transactions-and-concurrency.md"
        output_file = output_dir / f"{skill_name}.md"

        # Generate Windsurf rules content
        lines = []
        lines.append(f"# {name}")
        lines.append("")
        lines.append(description)
        lines.append("")
        lines.append(rules)

        # Write file
        output_file.write_text('\n'.join(lines), encoding='utf-8')
        generated_files += 1
        print(f"  ✓ Generated {output_file.name}")

    print(f"✓ Generated {generated_files} Windsurf rules files")
    return True


def generate_cline_rules(skills_dir: Path, output_dir: Path) -> bool:
    """Generate Cline .clinerules files from skills."""
    print(f"Generating Cline rules at {output_dir}")

    # Find all skill directories
    skill_dirs = [d for d in skills_dir.iterdir() if d.is_dir()]

    if not skill_dirs:
        print("ERROR: No skill directories found")
        return False

    # Create output directory
    output_dir.mkdir(parents=True, exist_ok=True)

    generated_files = 0

    for skill_dir in sorted(skill_dirs):
        skill_name = skill_dir.name
        skill_file = skill_dir / "SKILL.md"

        if not skill_file.exists():
            continue

        # Extract frontmatter
        frontmatter = extract_frontmatter(skill_file)
        name = frontmatter.get('name', skill_name)
        description = frontmatter.get('description', '')

        # Extract rules
        rules = extract_rules_from_skill(skill_file)

        if not rules:
            continue

        # Determine output filename
        # Cline uses .clinerules extension
        output_file = output_dir / f"{skill_name}.clinerules"

        # Generate Cline rules content
        lines = []
        lines.append(f"# {name}")
        lines.append("")
        lines.append(description)
        lines.append("")
        lines.append(rules)

        # Write file
        output_file.write_text('\n'.join(lines), encoding='utf-8')
        generated_files += 1
        print(f"  ✓ Generated {output_file.name}")

    print(f"✓ Generated {generated_files} Cline rules files")
    return True


def main():
    """Main generation function."""
    skills_dir = Path("skills")

    if not skills_dir.exists():
        print("ERROR: skills directory not found")
        return 1

    # Create output directories
    agents_md_path = Path("AGENTS.md")
    windsurf_rules_dir = Path(".windsurfrules")
    cline_rules_dir = Path(".clinerules")

    # Clean existing generated files
    if agents_md_path.exists():
        agents_md_path.unlink()
        print(f"Removed existing {agents_md_path}")

    if windsurf_rules_dir.exists():
        shutil.rmtree(windsurf_rules_dir)
        print(f"Removed existing {windsurf_rules_dir}")

    if cline_rules_dir.exists():
        shutil.rmtree(cline_rules_dir)
        print(f"Removed existing {cline_rules_dir}")

    # Generate all formats
    success = True

    if not generate_agents_md(skills_dir, agents_md_path):
        success = False

    if not generate_windsurf_rules(skills_dir, windsurf_rules_dir):
        success = False

    if not generate_cline_rules(skills_dir, cline_rules_dir):
        success = False

    if success:
        print("\n✅ All agent formats generated successfully!")
        print(f"\nGenerated files:")
        print(f"  - {agents_md_path} ({agents_md_path.stat().st_size} bytes)")
        print(f"  - {len(list(windsurf_rules_dir.rglob('*.md')))} Windsurf rules files")
        print(f"  - {len(list(cline_rules_dir.rglob('*.clinerules')))} Cline rules files")
        return 0
    else:
        print("\n❌ Failed to generate some agent formats")
        return 1


if __name__ == "__main__":
    exit(main())