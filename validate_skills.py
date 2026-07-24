#!/usr/bin/env python3
"""
Validate skill files and C# samples.
This script is used by the GitHub Actions workflow to validate skill files.
"""

import os
import re
import subprocess
import tempfile
import shutil
from pathlib import Path


def validate_frontmatter(skill_file: Path) -> bool:
    """Validate skill frontmatter has required fields."""
    content = skill_file.read_text(encoding='utf-8')

    # Check for frontmatter markers
    if not content.startswith('---'):
        print(f"ERROR: Missing frontmatter markers in {skill_file}")
        return False

    # Extract frontmatter section
    frontmatter_match = re.match(r'---\n(.*?)---', content, re.DOTALL)
    if not frontmatter_match:
        print(f"ERROR: Malformed frontmatter in {skill_file}")
        return False

    frontmatter = frontmatter_match.group(1)

    # Parse key-value pairs
    fields = {}
    for line in frontmatter.strip().split('\n'):
        if ':' in line:
            key, value = line.split(':', 1)
            fields[key.strip()] = value.strip()

    # Check required fields
    required_fields = ['name', 'description']
    for field in required_fields:
        if field not in fields:
            print(f"ERROR: Missing '{field}' field in {skill_file}")
            return False
        if not fields[field]:
            print(f"ERROR: Empty '{field}' field in {skill_file}")
            return False

    # Validate name format (lowercase with hyphens)
    name = fields['name']
    if any(c.isupper() for c in name):
        print(f"ERROR: Skill name should be lowercase with hyphens: {name} in {skill_file}")
        return False

    # Validate name doesn't contain spaces or special chars (except hyphens)
    if not re.match(r'^[a-z0-9-]+$', name):
        print(f"ERROR: Skill name should only contain lowercase letters, numbers, and hyphens: {name} in {skill_file}")
        return False

    print(f"✓ Valid frontmatter in {skill_file}")
    return True


def extract_csharp_blocks(skill_file: Path) -> list[tuple[int, str]]:
    """Extract C# code blocks from skill file."""
    content = skill_file.read_text(encoding='utf-8')

    # Find all fenced code blocks with csharp language
    pattern = r'```csharp\n(.*?)```'
    matches = re.finditer(pattern, content, re.DOTALL)

    blocks = []
    for match in matches:
        code = match.group(1).strip()
        # Get approximate line number
        line_num = content[:match.start()].count('\n') + 1
        blocks.append((line_num, code))

    return blocks


def validate_csharp_sample(skill_file: Path, line_num: int, code: str) -> bool:
    """Validate a C# sample by attempting to compile it."""
    # Check for opt-out marker
    if '// non-compiling: illustrative' in code:
        print(f"  Skipping non-compiling block (line {line_num}) in {skill_file}")
        return True

    # Try to compile the code as-is first
    with tempfile.TemporaryDirectory() as tmpdir:
        proj_dir = Path(tmpdir) / "sample"
        proj_dir.mkdir()

        # Create csproj
        csproj = proj_dir / "sample.csproj"
        csproj.write_text("""<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>
    <OutputType>Exe</OutputType>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.EntityFrameworkCore" Version="8.0.0" />
    <PackageReference Include="Microsoft.EntityFrameworkCore.SqlServer" Version="8.0.0" />
  </ItemGroup>
</Project>
""")

        # Create Program.cs with the extracted code
        # Try to detect if this is a method/class and wrap appropriately
        program_cs = proj_dir / "Program.cs"

        # If code contains async/await and looks like a method body, wrap it
        if 'async Task' in code or 'async void' in code or 'await' in code:
            # Wrap in a class with proper structure
            wrapped_code = f"""// Extracted from: {skill_file}
// Line: {line_num}

using System;
using System.Threading.Tasks;
using Microsoft.EntityFrameworkCore;

public class Program
{{
    public static async Task Main()
    {{
        // This is a sample extracted from skill documentation
        {code}
    }}
}}
"""
        else:
            # Simple top-level statements
            wrapped_code = f"""// Extracted from: {skill_file}
// Line: {line_num}

using System;
using System.Threading.Tasks;
using Microsoft.EntityFrameworkCore;

{code}
"""

        program_cs.write_text(wrapped_code)

        # Try to build
        try:
            result = subprocess.run(
                ["dotnet", "build", "-v", "quiet", "-c", "Release"],
                cwd=proj_dir,
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode != 0:
                # If it fails, try with more context
                if 'Microsoft.EntityFrameworkCore' not in code:
                    # Add using directive
                    wrapped_code_v2 = wrapped_code.replace(
                        'using System;',
                        'using System;\nusing Microsoft.EntityFrameworkCore;'
                    )
                    program_cs.write_text(wrapped_code_v2)

                    result = subprocess.run(
                        ["dotnet", "build", "-v", "quiet", "-c", "Release"],
                        cwd=proj_dir,
                        capture_output=True,
                        text=True,
                        timeout=30
                    )

                if result.returncode != 0:
                    print(f"ERROR: Failed to build sample (line {line_num}) from {skill_file}")
                    if result.stdout:
                        print("STDOUT:", result.stdout[:500])
                    if result.stderr:
                        print("STDERR:", result.stderr[:500])
                    return False

            print(f"  ✓ Compiled sample (line {line_num}) from {skill_file}")
            return True

        except subprocess.TimeoutExpired:
            print(f"ERROR: Timeout building sample (line {line_num}) from {skill_file}")
            return False
        except Exception as e:
            print(f"ERROR: Exception building sample (line {line_num}) from {skill_file}: {e}")
            return False


def main():
    """Main validation function."""
    skills_dir = Path("skills")

    if not skills_dir.exists():
        print("ERROR: skills directory not found")
        return 1

    # Find all skill files
    skill_files = list(skills_dir.rglob("SKILL.md"))

    if not skill_files:
        print("ERROR: No SKILL.md files found")
        return 1

    print(f"Found {len(skill_files)} skill files to validate")
    print()

    all_valid = True

    # Validate frontmatter for all skill files
    print("=== Validating skill frontmatter ===")
    for skill_file in skill_files:
        if not validate_frontmatter(skill_file):
            all_valid = False
    print()

    # Extract and validate C# samples
    print("=== Validating C# samples ===")
    for skill_file in skill_files:
        print(f"Processing {skill_file}:")
        blocks = extract_csharp_blocks(skill_file)

        if not blocks:
            print(f"  ℹ No C# samples found in {skill_file}")
            continue

        for line_num, code in blocks:
            if not validate_csharp_sample(skill_file, line_num, code):
                all_valid = False

    print()
    if all_valid:
        print("✅ All validations passed!")
        return 0
    else:
        print("❌ Some validations failed!")
        return 1


if __name__ == "__main__":
    exit(main())
