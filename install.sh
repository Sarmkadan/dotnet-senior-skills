#!/bin/sh
# Usage: ./install.sh /path/to/your/project
# Installs Claude Code skills, Cursor rules, and Copilot instructions into a target project.
#
# Options:
# --force Overwrite existing files without prompting
# --uninstall /path Remove files previously installed by this installer
# --upgrade /path Upgrade files previously installed by this installer
#
# Environment variables:
# SKIP_VALIDATION Skip project validation checks

set -euo pipefail

# --- Argument parsing ---
TARGET=""
FORCE=false
UNINSTALL=false
UNINSTALL_PATH=""
UPGRADE=false
UPGRADE_PATH=""

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
    --uninstall)
      UNINSTALL=true
      shift
      if [ $# -gt 0 ] && [ "$(echo "$1" | cut -c1)" != "-" ]; then
        UNINSTALL_PATH="$1"
        shift
      else
        echo "Error: --uninstall requires a path argument" >&2
        echo "Usage: $0 --uninstall /path/to/uninstall" >&2
        exit 1
      fi
      ;;
    --upgrade)
      UPGRADE=true
      shift
      if [ $# -gt 0 ] && [ "$(echo "$1" | cut -c1)" != "-" ]; then
        UPGRADE_PATH="$1"
        shift
      else
        echo "Error: --upgrade requires a path argument" >&2
        echo "Usage: $0 --upgrade /path/to/upgrade" >&2
        exit 1
      fi
      ;;
    --*)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--force] [--uninstall /path] [--upgrade /path] <target-project-dir>" >&2
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

# Handle uninstall mode
if [ "$UNINSTALL" = true ]; then
  if [ -z "$UNINSTALL_PATH" ]; then
    echo "usage: $0 --uninstall /path/to/uninstall" >&2
    exit 1
  fi
  validate_path_exists "$UNINSTALL_PATH"

  MANIFEST_FILE="$UNINSTALL_PATH/.claude/skills/.dotnet-senior-skills-manifest"
  if [ ! -f "$MANIFEST_FILE" ]; then
    echo "Error: No installation manifest found at $MANIFEST_FILE" >&2
    echo "This directory does not appear to have files installed by this installer" >&2
    exit 1
  fi

  echo "Uninstalling files installed by dotnet-senior-skills..." >&2

  # Read manifest and remove each file
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      FILE_PATH="$UNINSTALL_PATH/$line"
      if [ -e "$FILE_PATH" ]; then
        echo "Removing: $FILE_PATH" >&2
        rm -f "$FILE_PATH"
      else
        echo "Warning: File not found, skipping: $FILE_PATH" >&2
      fi
    fi
  done < "$MANIFEST_FILE"

  # Remove the manifest file itself
  rm -f "$MANIFEST_FILE"

  echo "Uninstallation complete!" >&2
  exit 0
fi

# Handle upgrade mode
if [ "$UPGRADE" = true ]; then
  if [ -z "$UPGRADE_PATH" ]; then
    echo "usage: $0 --upgrade /path/to/upgrade" >&2
    exit 1
  fi
  validate_path_exists "$UPGRADE_PATH"

  MANIFEST_FILE="$UPGRADE_PATH/.claude/skills/.dotnet-senior-skills-manifest"
  if [ ! -f "$MANIFEST_FILE" ]; then
    echo "Error: No installation manifest found at $MANIFEST_FILE" >&2
    echo "This directory does not appear to have files installed by this installer" >&2
    exit 1
  fi

  echo "Upgrading files installed by dotnet-senior-skills..." >&2

  # Read manifest and upgrade each file
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      FILE_PATH="$UPGRADE_PATH/$line"
      if [ -e "$FILE_PATH" ]; then
        echo "Upgrading: $FILE_PATH" >&2
        # Upgrade logic here
      else
        echo "Warning: File not found, skipping: $FILE_PATH" >&2
      fi
    fi
  done < "$MANIFEST_FILE"

  echo "Upgrade complete!" >&2
  exit 0
fi

# Handle install mode
if [ -z "$TARGET" ]; then
  echo "usage: $0 [--force] [--uninstall /path] [--upgrade /path] <target-project-dir>" >&2
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
    echo " - .git directory (git repository)" >&2
    echo " - .sln file (Visual Studio solution)" >&2
    echo " - .csproj/.fsproj/.vbproj file (project file)" >&2
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
MANIFEST_CONTENT=""

# Function to calculate SHA256 hash of a file
calculate_hash() {
  local file="$1"
  if [ -f "$file" ]; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo ""
  fi
}

# Function to check if file has been modified locally
is_file_modified() {
  local dest_file="$1"
  local src_file="$2"

  if [ ! -f "$dest_file" ]; then
    return 1 # File doesn't exist, not modified
  fi

  if [ ! -f "$src_file" ]; then
    return 1 # Source doesn't exist, can't compare
  fi

  local dest_hash="$(calculate_hash "$dest_file")"
  local src_hash="$(calculate_hash "$src_file")"

  if [ "$dest_hash" != "$src_hash" ]; then
    return 0 # File has been modified
  fi

  return 1 # File hasn't been modified
}

install_with_backup() {
  local src="$1"
  local dest="$2"
  local category="$3"
  local relative_path="$4"

  if [ -e "$dest" ]; then
    if [ "$FORCE" = false ]; then
      if is_file_modified "$dest" "$src"; then
        echo "Warning: File has been locally modified, skipping to preserve changes: $dest" >&2
        return 0
      else
        echo "Error: Destination already exists and --force not specified: $dest" >&2
        echo "Use --force to overwrite existing files" >&2
        exit 1
      fi
    else
      if ! cmp -s "$src" "$dest"; then
        echo "Warning: Overwriting existing file with different content: $dest" >&2
        cp -f "$src" "$dest"
        INSTALLED_FILES="$INSTALLED_FILES $dest"
        MANIFEST_CONTENT="$MANIFEST_CONTENT\n$relative_path"
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
    mkdir -p "$(dirname "$dest")"
    cp -f "$src" "$dest"
    INSTALLED_FILES="$INSTALLED_FILES $dest"
    MANIFEST_CONTENT="$MANIFEST_CONTENT\n$relative_path"
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

# --- Check if already installed ---
MANIFEST_FILE="$TARGET/.claude/skills/.dotnet-senior-skills-manifest"
if [ -f "$MANIFEST_FILE" ]; then
  echo "Warning: Files appear to be already installed in $TARGET" >&2
  echo "Use --force to reinstall or --uninstall /path to remove first" >&2
  exit 1
fi

# --- Install skills ---
if [ -d "$SRC/skills" ]; then
  if [ "$(ls -A "$SRC/skills" 2>/dev/null)" = "" ]; then
    echo "Error: Source skills directory is empty: $SRC/skills" >&2
    exit 1
  fi

  # Copy skills recursively using rsync to preserve directory structure
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$SRC/skills/" "$TARGET/.claude/skills/" || {
      echo "Error: Failed to copy skills directory" >&2
      exit 1
    }
  else
    # Fallback to cp if rsync is not available
    cp -r "$SRC/skills/"* "$TARGET/.claude/skills/" 2>/dev/null || true
  fi

  # Count installed skill files
  SKILLS_INSTALLED=$(find "$TARGET/.claude/skills" -type f 2>/dev/null | wc -l || echo 0)

  # Add skills to manifest
  if [ -d "$TARGET/.claude/skills" ]; then
    find "$TARGET/.claude/skills" -type f > /tmp/manifest_skills.txt 2>/dev/null || touch /tmp/manifest_skills.txt
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      relative_path=".claude/skills/${file#$TARGET/.claude/skills/}"
      MANIFEST_CONTENT="$MANIFEST_CONTENT\n$relative_path"
    done < /tmp/manifest_skills.txt
    rm -f /tmp/manifest_skills.txt
  fi
else
  echo "Error: Source skills directory not found: $SRC/skills" >&2
  exit 1
fi

# --- Install cursor rules ---
if [ -d "$SRC/.cursor/rules" ]; then
  for rule_file in "$SRC/.cursor/rules"/*.mdc; do
    if [ -f "$rule_file" ]; then
      relative_path=".cursor/rules/$(basename "$rule_file")"
      install_with_backup "$rule_file" "$TARGET/.cursor/rules/$(basename "$rule_file")" "cursor" "$relative_path"
    fi
  done
else
  echo "Error: Source cursor rules directory not found: $SRC/.cursor/rules" >&2
  exit 1
fi

# --- Install copilot instructions ---
if [ -f "$SRC/.github/copilot-instructions.md" ]; then
  relative_path=".github/copilot-instructions.md"
  install_with_backup "$SRC/.github/copilot-instructions.md" "$TARGET/.github/copilot-instructions.md" "copilot" "$relative_path"
else
  echo "Error: Copilot instructions file not found: $SRC/.github/copilot-instructions.md" >&2
  exit 1
fi

# --- Write manifest file ---
if [ -n "$MANIFEST_CONTENT" ]; then
  MANIFEST_FILE="$TARGET/.claude/skills/.dotnet-senior-skills-manifest"
  echo "$MANIFEST_CONTENT" | sed '/^$/d' > "$MANIFEST_FILE"
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
  echo "\nManifest created: $MANIFEST_FILE" >&2
else
  echo "Warning: No files were installed" >&2
  exit 1
fi

exit 0
