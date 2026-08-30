#!/usr/bin/env python3
"""Generate AGENTS.md and Windsurf/Cline rules from the skills directory."""

import re
import shutil
from pathlib import Path
from typing import TypedDict


class SkillModel(TypedDict):
    """Data needed to render one skill in every supported format."""

    name: str
    description: str
    rules: str
    skill_name: str


CATEGORY_MAP: dict[str, str] = {
    "ef": "EF Core",
    "async": "Async",
    "di": "DI",
    "http": "HTTP",
    "ef-core": "EF Core",
    "api": "API",
    "domain": "Domain",
    "testing": "Testing",
    "security": "Security",
    "performance": "Performance",
    "concurrency": "Concurrency",
    "disposal": "Disposal",
    "logging": "Logging",
    "datetime": "Date/Time",
    "globalization": "Globalization",
    "collections": "Collections",
    "middleware": "Middleware",
    "nullable": "Nullability",
    "serialization": "Serialization",
    "solid": "SOLID",
    "memory": "Memory",
    "background": "Background Work",
    "configuration": "Configuration",
    "exception": "Errors",
    "input": "Input Validation",
}


def parse_frontmatter(content: str) -> dict[str, str] | None:
    """Parse the simple key-value frontmatter used by skill files."""
    match = re.match(r"---\n(.*?)---", content, re.DOTALL)
    if match is None:
        return None

    fields: dict[str, str] = {}
    for line in match.group(1).strip().split("\n"):
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    return fields


def extract_rules(content: str) -> str | None:
    """Extract rules beginning at the first level-two Markdown heading."""
    for index, line in enumerate(content.split("\n")):
        if line.startswith("## ") and index > 0:
            return "\n".join(content.split("\n")[index:])
    return None


def build_skill_model(
    skill_name: str, content: str, frontmatter: dict[str, str]
) -> SkillModel | None:
    """Convert parsed skill data to the shared generation model."""
    rules = extract_rules(content)
    if rules is None:
        return None

    return {
        "name": frontmatter.get("name", skill_name),
        "description": frontmatter.get("description", ""),
        "rules": rules,
        "skill_name": skill_name,
    }


def read_skill(skill_file: Path) -> SkillModel | None:
    """Read and parse one skill file, warning when frontmatter is absent."""
    content = skill_file.read_text(encoding="utf-8")
    frontmatter = parse_frontmatter(content)
    if frontmatter is None:
        print(f"WARNING: Missing or malformed frontmatter in {skill_file}; using defaults")
        frontmatter = {}
    return build_skill_model(skill_file.parent.name, content, frontmatter)


def load_skills(skills_dir: Path) -> list[SkillModel]:
    """Load valid skill models in deterministic declared-name order."""
    models = [
        model
        for skill_dir in skills_dir.iterdir()
        if skill_dir.is_dir() and (skill_file := skill_dir / "SKILL.md").exists()
        if (model := read_skill(skill_file)) is not None
    ]
    return sorted(models, key=lambda model: (model["name"], model["skill_name"]))


def category_for(skill_name: str) -> str:
    """Return the AGENTS.md category for a skill directory name."""
    prefix = skill_name.split("-")[0]
    return CATEGORY_MAP.get(prefix, prefix.title())


def render_agents_md(skills: list[SkillModel]) -> str:
    """Render all skill models as AGENTS.md content."""
    lines = [
        "# .NET Senior Engineering Rules",
        "",
        "Condensed rules for this codebase. Full versions with rationale and examples live in `skills/`.",
        "",
    ]
    for skill in skills:
        category = category_for(skill["skill_name"])
        if f"## {category}" not in "\n".join(lines):
            lines.extend(("", f"## {category}", ""))
        lines.append(skill["rules"])
    return "\n".join(lines)


def render_rule(skill: SkillModel) -> str:
    """Render one skill in the shared Windsurf/Cline rule format."""
    return "\n".join(
        (f'# {skill["name"]}', "", skill["description"], "", skill["rules"])
    )


def write_text(output_path: Path, content: str) -> None:
    """Write rendered content, creating its parent directory if needed."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(content, encoding="utf-8")


def write_agents_md(skills: list[SkillModel], output_path: Path) -> None:
    """Write the combined AGENTS.md output."""
    print(f"Generating AGENTS.md at {output_path}")
    write_text(output_path, render_agents_md(skills))
    print(f"✓ Generated AGENTS.md with {len(skills)} rule sets")


def write_rule_files(
    skills: list[SkillModel], output_dir: Path, extension: str, format_name: str
) -> None:
    """Write one rendered rule file for each skill."""
    print(f"Generating {format_name} rules at {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    for skill in skills:
        output_file = output_dir / f'{skill["skill_name"]}{extension}'
        write_text(output_file, render_rule(skill))
        print(f"  ✓ Generated {output_file.name}")
    print(f"✓ Generated {len(skills)} {format_name} rules files")


def clean_outputs(agents_path: Path, output_dirs: tuple[Path, ...]) -> None:
    """Remove prior generated outputs before writing replacements."""
    if agents_path.exists():
        agents_path.unlink()
        print(f"Removed existing {agents_path}")
    for output_dir in output_dirs:
        if output_dir.exists():
            shutil.rmtree(output_dir)
            print(f"Removed existing {output_dir}")


def main() -> int:
    """Generate every supported rules format."""
    skills_dir = Path("skills")
    if not skills_dir.exists():
        print("ERROR: skills directory not found")
        return 1

    skills = load_skills(skills_dir)
    if not skills:
        print("ERROR: No valid skill rules found")
        return 1

    agents_path = Path("AGENTS.md")
    windsurf_dir = Path(".windsurfrules")
    cline_dir = Path(".clinerules")
    clean_outputs(agents_path, (windsurf_dir, cline_dir))

    write_agents_md(skills, agents_path)
    write_rule_files(skills, windsurf_dir, ".md", "Windsurf")
    write_rule_files(skills, cline_dir, ".clinerules", "Cline")

    print("\n✅ All agent formats generated successfully!")
    print("\nGenerated files:")
    print(f"  - {agents_path} ({agents_path.stat().st_size} bytes)")
    print(f"  - {len(skills)} Windsurf rules files")
    print(f"  - {len(skills)} Cline rules files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
