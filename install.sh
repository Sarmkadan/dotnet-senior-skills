#!/bin/sh
# Usage: ./install.sh /path/to/your/project
# Installs Claude Code skills, Cursor rules, and Copilot instructions into a target project.
#
# Options:
# --force Overwrite existing files without prompting
#
# Environment variables:
# SKIP_VALIDATION Skip project validation checks

set -euo pipefail

# --- Argument parsing ---
TARGET=""
FORCE=false

validate_path_exists() {
  local path="$1"
  if [ ! -d "$path" ]; then
    echo "Error: Target directory does not exist: $path" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
case "$1" in
--force)
FORCE=true
shift
;;
--*)
 echo "Unknown option: $1" >&2
 echo "Usage: $0 [--force] <target-project-dir>" >&2
 exit 1
;;
*)
 if [ -z "$TARGET" ]; then
  TARGET="$1"
  shift
else
  echo "Multiple targets specified" >&2
  exit 1
fi
;;
esac
done

if [ -z "$TARGET" ]; then
 echo "usage: $0 [--force] <target-project-dir>" >&2
 exit 1
fi

validate_path_exists "$TARGET"

# --- Enhanced validation ---
if [ -z "${SKIP_VALIDATION+x}" ]; then
  has_project=false
  has_git=false
  has_solution=false
  has_project_file=false

  # Check for .git directory
  if [ -d "$TARGET/.git" ]; then
    has_git=true
  fi

  # Check for solution files (.sln)
  if [ -n "$(find "$TARGET" -maxdepth 1 -name "*.sln" -print -quit 2>/dev/null)" ]; then
    has_solution=true
  fi

  # Check for project files (.csproj, .fsproj, .vbproj)
  if [ -n "$(find "$TARGET" -maxdepth 1 \( -name "*.csproj" -o -name "*.fsproj" -o -name "*.vbproj" \) -print -quit 2>/dev/null)" ]; then
    has_project_file=true
  fi

  # Validate project structure
  if [ "$has_git$has_solution$has_project_file" = "falsefalsefalse" ]; then
    echo "Error: Target directory '$TARGET' does not appear to be a valid project root" >&2
    echo "Expected to find at least one of:" >&2
    echo "  - .git directory (git repository)" >&2
    echo "  - .sln file (Visual Studio solution)" >&2
    echo "  - .csproj/.fsproj/.vbproj file (project file)" >&2
    exit 1
  fi

  if [ "$has_git" = false ] && [ "$has_solution$has_project_file" = "falsefalse" ]; then
    echo "Warning: Target directory '$TARGET' does not appear to be a git repository" >&2
    echo "but contains solution or project files. Proceeding anyway." >&2
  fi
fi

# --- Source directory ---
SRC="$(cd "$(dirname "$0")" && pwd)"

# --- Installation tracking ---
INSTALLED_FILES=""
SKILLS_INSTALLED=0
CURSOR_RULES_INSTALLED=0
COPILOT_INSTRUCTIONS_INSTALLED=0

install_with_backup() {
  local src="$1"
  local dest="$2"
  local category="$3"

  if [ -e "$dest" ]; then
    if [ "$FORCE" = false ]; then
      echo "Error: Destination already exists and --force not specified: $dest" >&2
      echo "Use --force to overwrite existing files" >&2
      exit 1
    else
      if ! cmp -s "$src" "$dest"; then
        echo "Warning: Overwriting existing file with different content: $dest" >&2
        cp -f "$src" "$dest"
        INSTALLED_FILES="$INSTALLED_FILES $dest"
        case "$category" in
          "skills")
            SKILLS_INSTALLED=$((SKILLS_INSTALLED + 1))
            ;;
          "cursor")
            CURSOR_RULES_INSTALLED=$((CURSOR_RULES_INSTALLED + 1))
            ;;
          "copilot")
            COPILOT_INSTRUCTIONS_INSTALLED=$((COPILOT_INSTRUCTIONS_INSTALLED + 1))
            ;;
        esac
      else
        echo "Skipping unchanged file: $dest" >&2
      fi
    fi
  else
    cp -f "$src" "$dest"
    INSTALLED_FILES="$INSTALLED_FILES $dest"
    case "$category" in
      "skills")
        SKILLS_INSTALLED=$((SKILLS_INSTALLED + 1))
        ;;
      "cursor")
        CURSOR_RULES_INSTALLED=$((CURSOR_RULES_INSTALLED + 1))
        ;;
      "copilot")
        COPILOT_INSTRUCTIONS_INSTALLED=$((COPILOT_INSTRUCTIONS_INSTALLED + 1))
        ;;
    esac
  fi
}

# --- Create target directories ---
mkdir -p "$TARGET/.claude/skills" "$TARGET/.cursor/rules" "$TARGET/.github" || {
  echo "Error: Failed to create target directories in $TARGET" >&2
  exit 1
}

# --- Install skills ---
if [ -d "$SRC/skills" ]; then
  if [ "$(ls -A "$SRC/skills" 2>/dev/null)" = "" ]; then
    echo "Error: Source skills directory is empty: $SRC/skills" >&2
    exit 1
  fi

  for skill_file in "$SRC/skills"/*.mdc; do
    if [ -f "$skill_file" ]; then
      install_with_backup "$skill_file" "$TARGET/.claude/skills/$(basename "$skill_file")" "skills"
    fi
  done
else
  echo "Error: Source skills directory not found: $SRC/skills" >&2
  exit 1
fi

# --- Install cursor rules ---
if [ -d "$SRC/.cursor/rules" ]; then
  for rule_file in "$SRC/.cursor/rules"/*.mdc; do
    if [ -f "$rule_file" ]; then
      install_with_backup "$rule_file" "$TARGET/.cursor/rules/$(basename "$rule_file")" "cursor"
    fi
  done
else
  echo "Error: Source cursor rules directory not found: $SRC/.cursor/rules" >&2
  exit 1
fi

# --- Install copilot instructions ---
if [ -f "$SRC/.github/copilot-instructions.md" ]; then
  install_with_backup "$SRC/.github/copilot-instructions.md" "$TARGET/.github/copilot-instructions.md" "copilot"
else
  echo "Error: Copilot instructions file not found: $SRC/.github/copilot-instructions.md" >&2
  exit 1
fi

# --- Summary ---
echo "Installation successful!" >&2
echo "Installed components:" >&2
echo " - Claude Code skills: $SKILLS_INSTALLED" >&2
echo " - Cursor rules: $CURSOR_RULES_INSTALLED" >&2
echo " - Copilot instructions: $COPILOT_INSTRUCTIONS_INSTALLED" >&2

if [ -n "$INSTALLED_FILES" ]; then
  echo "\nInstalled files:" >&2
  for file in $INSTALLED_FILES; do
    echo " - $file" >&2
  done
  echo "\nTarget: $TARGET" >&2
else
  echo "Warning: No files were installed" >&2
  exit 1
fi

exit 0