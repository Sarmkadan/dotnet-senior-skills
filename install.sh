#!/bin/sh
# Usage: ./install.sh [--tools TOOLS] [--only CATEGORIES] [--skip CATEGORIES] [--force] [--uninstall /path] [--upgrade /path] <target-project-dir>
# Installs Claude Code skills, Cursor rules, and Copilot instructions into a target project.
#
# Options:
# --tools TOOLS Comma-separated list of tool formats to install (claude,cursor,copilot,agents,windsurf,cline). Default: all detected tools
# --only CATEGORIES Comma-separated list of skill categories to install (e.g., ef,async,globalization)
# --skip CATEGORIES Comma-separated list of skill categories to skip (e.g., ef,globalization)
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
TOOLS=""
ONLY_CATEGORIES=""
SKIP_CATEGORIES=""

# --- Helper functions ---

# Extract category from skill directory name
# e.g., "ef-core-transactions-and-concurrency" -> "ef"
# e.g., "async-await-pitfalls" -> "async"
# e.g., "globalization-and-culture" -> "globalization"
extract_category() {
  local dir_name="$1"

  # Remove leading path if present
  dir_name=$(basename "$dir_name")

  # Extract first segment before dash
  category=$(echo "$dir_name" | cut -d'-' -f1)

  # Normalize to lowercase
  echo "$category" | tr '[:upper:]' '[:lower:]'
}

# Check if a category should be included based on --only and --skip filters
should_install_category() {
  local category="$1"

  # If --only is specified, only install matching categories
  if [ -n "$ONLY_CATEGORIES" ]; then
    for filter in $(echo "$ONLY_CATEGORIES" | tr ',' ' '); do
      if [ "$category" = "$filter" ]; then
        return 0  # Include this category
      fi
    done
    return 1  # Exclude this category
  fi

  # If --skip is specified, exclude matching categories
  if [ -n "$SKIP_CATEGORIES" ]; then
    for filter in $(echo "$SKIP_CATEGORIES" | tr ',' ' '); do
      if [ "$category" = "$filter" ]; then
        return 1  # Exclude this category
      fi
    done
  fi

  # Default: include the category
  return 0
}

validate_path_exists() {
  local path="$1"
  if [ ! -d "$path" ]; then
    echo "Error: Target directory does not exist: $path" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tools)
      shift
      if [ $# -gt 0 ] && [ "$(echo "$1" | cut -c1)" != "-" ]; then
        TOOLS="$1"
        shift
      else
        echo "Error: --tools requires a comma-separated list of tools" >&2
        echo "Usage: $0 --tools claude,cursor,copilot <target>" >&2
        exit 1
      fi
      ;;
    --only)
      shift
      if [ $# -gt 0 ] && [ "$(echo "$1" | cut -c1)" != "-" ]; then
        ONLY_CATEGORIES="$1"
        shift
      else
        echo "Error: --only requires a comma-separated list of categories" >&2
        echo "Usage: $0 --only ef,async <target>" >&2
        exit 1
      fi
      ;;
    --skip)
      shift
      if [ $# -gt 0 ] && [ "$(echo "$1" | cut -c1)" != "-" ]; then
        SKIP_CATEGORIES="$1"
        shift
      else
        echo "Error: --skip requires a comma-separated list of categories" >&2
        echo "Usage: $0 --skip ef,globalization <target>" >&2
        exit 1
      fi
      ;;
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
      echo "Usage: $0 [--tools TOOLS] [--only CATEGORIES] [--skip CATEGORIES] [--force] [--uninstall /path] [--upgrade /path] <target-project-dir>" >&2
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

# --- Tool detection and validation ---
# Auto-detect tools if --tools flag is not provided
if [ -z "$TOOLS" ]; then
  # Check for .claude directory in target project
  if [ -d "$TARGET/.claude" ]; then
    TOOLS="claude"
  fi

  # Check for .cursor directory in target project
  if [ -d "$TARGET/.cursor" ]; then
    if [ -z "$TOOLS" ]; then
      TOOLS="cursor"
    else
      TOOLS="$TOOLS,cursor"
    fi
  fi

  # Check for .github/copilot-instructions.md in target project
  if [ -f "$TARGET/.github/copilot-instructions.md" ]; then
    if [ -z "$TOOLS" ]; then
      TOOLS="copilot"
    else
      TOOLS="$TOOLS,copilot"
    fi
  fi


# Check for AGENTS.md in source directory (indicates new format support)
if [ -f "$SRC/AGENTS.md" ]; then
if [ -z "$TOOLS" ]; then
TOOLS="agents"
else
TOOLS="$TOOLS,agents"
fi
fi

# If no tools detected, default to all six formats
  # If no tools detected, default to all three
  if [ -z "$TOOLS" ]; then
    TOOLS="claude,cursor,copilot,agents,windsurf,cline"
  fi

  # Normalize detected tools to lowercase
  TOOLS=$(echo "$TOOLS" | tr '[:upper:]' '[:lower:]')
fi

# Parse --tools argument
# Normalize tools to lowercase
TOOLS=$(echo "$TOOLS" | tr '[:upper:]' '[:lower:]')

# Validate tools
for tool in $(echo "$TOOLS" | tr ',' ' '); do
  case "$tool" in
    claude|cursor|copilot|agents|windsurf|cline)
      # Valid tool
      ;;
    *)
      echo "Error: Invalid tool specified: $tool" >&2
      echo "Valid tools: claude, cursor, copilot, agents, windsurf, cline" >&2
      exit 1
      ;;
  esac
done

# Parse --only and --skip arguments
if [ -n "$ONLY_CATEGORIES" ] && [ -n "$SKIP_CATEGORIES" ]; then
  echo "Error: Cannot use both --only and --skip together" >&2
  exit 1
fi

# Normalize categories to lowercase
if [ -n "$ONLY_CATEGORIES" ]; then
  ONLY_CATEGORIES=$(echo "$ONLY_CATEGORIES" | tr '[:upper:]' '[:lower:]')
fi

if [ -n "$SKIP_CATEGORIES" ]; then
  SKIP_CATEGORIES=$(echo "$SKIP_CATEGORIES" | tr '[:upper:]' '[:lower:]')
fi

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
# Add version metadata to skill files after upgrade
if [[ "$line" == .claude/skills/* ]]; then
 add_version_metadata "$FILE_PATH" "$VERSION" "$SOURCE_COMMIT"
fi
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

# --- Version information ---
VERSION=""
SOURCE_COMMIT=""

# Read version from VERSION file if it exists
if [ -f "$SRC/VERSION" ]; then
  VERSION=$(cat "$SRC/VERSION" | tr -d '\n' | tr -d '\r')
fi

# Get source commit hash if git is available
if command -v git >/dev/null 2>&1 && [ -d "$SRC/.git" ]; then
  SOURCE_COMMIT=$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo "")
fi

# If version is still empty, use a default
if [ -z "$VERSION" ]; then
  VERSION="unknown"
fi

# If source commit is empty, use a default
if [ -z "$SOURCE_COMMIT" ]; then
  SOURCE_COMMIT="unknown"
fi

# --- Installation tracking ---
INSTALLED_FILES=""
SKILLS_INSTALLED=0
CURSOR_RULES_INSTALLED=0
COPILOT_INSTRUCTIONS_INSTALLED=0
AGENTS_MD_INSTALLED=0
WINDSURF_RULES_INSTALLED=0
CLINE_RULES_INSTALLED=0
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

# Function to add version metadata to skill file frontmatter
add_version_metadata() {
  local file_path="$1"
  local version="$2"
  local source_commit="$3"

  # If it's a directory, recursively process all SKILL.md files
  if [ -d "$file_path" ]; then
    find "$file_path" -name "SKILL.md" -type f | while read -r skill_file; do
      add_version_metadata "$skill_file" "$version" "$source_commit"
    done
    return 0
  fi

  # Only process files with frontmatter (SKILL.md files)
  if ! grep -q '^---$' "$file_path" 2>/dev/null; then
    return 0
  fi

  # Check if file already has version metadata
  if grep -q '^version:' "$file_path" 2>/dev/null; then
    return 0
  fi

  if grep -q '^source-commit:' "$file_path" 2>/dev/null; then
    return 0
  fi

  # Create temporary file for processing
  local temp_file="$(mktemp)"

  # Use awk to insert version fields after the frontmatter start marker
  awk -v version="$version" -v commit="$source_commit" '
    BEGIN { added = 0 }
    /^---$/ {
      print
      if (added == 0) {
        print "version: " version
        print "source-commit: " commit
        added = 1
      }
      next
    }
    { print }
  ' "$file_path" > "$temp_file"

  # Replace original file with updated version
  mv "$temp_file" "$file_path"
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

  # Add version metadata to skill files after installation
  if [ "$category" = "skills" ]; then
    add_version_metadata "$dest" "$VERSION" "$SOURCE_COMMIT"
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

  # Install individual skill directories based on filters
  for skill_dir in "$SRC/skills"/*/; do
    if [ -d "$skill_dir" ]; then
      # Extract category from directory name
      category=$(extract_category "$skill_dir")

      # Check if this category should be installed
      if should_install_category "$category"; then
        # Copy this specific skill directory
        # Remove trailing slash to copy the directory itself
        skill_dir_no_slash="${skill_dir%/}"
skill_name=$(basename "$skill_dir_no_slash")
skill_dest="$TARGET/.claude/skills/$skill_name"
        if command -v rsync >/dev/null 2>&1; then
          rsync -a "$skill_dir_no_slash/" "$skill_dest/" || {
            echo "Error: Failed to copy skill directory: $skill_dir" >&2
            exit 1
          }
        else
          # Fallback to cp if rsync is not available
          cp -r "$skill_dir_no_slash" "$skill_dest" 2>/dev/null || true
        fi

      # Add version metadata to the installed skill files
      add_version_metadata "$skill_dest" "$VERSION" "$SOURCE_COMMIT"
      else
        echo "Skipping skill category: $category" >&2
      fi
    fi
  done

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
# Install cursor rules only if cursor tool is requested or no --tools filter is specified
cursor_should_install=true

if [ -n "$TOOLS" ]; then
  # Check if cursor tool is requested
  cursor_requested=false
  for tool in $(echo "$TOOLS" | tr ',' ' '); do
    if [ "$tool" = "cursor" ]; then
      cursor_requested=true
      break
    fi
  done

  if [ "$cursor_requested" = false ]; then
    cursor_should_install=false
    echo "Skipping Cursor rules installation (not requested via --tools)" >&2
  fi
fi

if [ "$cursor_should_install" = true ]; then
  if [ -d "$SRC/.cursor/rules" ]; then
    for rule_file in "$SRC/.cursor/rules"/*.mdc; do
      if [ -f "$rule_file" ]; then
        # Extract category from cursor rule filename
        # e.g., "ef-core-transactions-and-concurrency.mdc" -> "ef"
        filename=$(basename "$rule_file")
        category=$(echo "$filename" | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]')

        # Check if this category should be installed
        if should_install_category "$category"; then
          relative_path=".cursor/rules/$filename"
          install_with_backup "$rule_file" "$TARGET/.cursor/rules/$filename" "cursor" "$relative_path"
        else
          echo "Skipping cursor rule category: $category" >&2
        fi
      fi
    done
  fi
fi

# --- Install copilot instructions ---
# Install copilot instructions only if copilot tool is requested or no --tools filter is specified
copilot_should_install=true

if [ -n "$TOOLS" ]; then
  # Check if copilot tool is requested
  copilot_requested=false
  for tool in $(echo "$TOOLS" | tr ',' ' '); do
    if [ "$tool" = "copilot" ]; then
      copilot_requested=true
      break
    fi
  done

  if [ "$copilot_requested" = false ]; then
    copilot_should_install=false
    echo "Skipping Copilot instructions installation (not requested via --tools)" >&2
  fi
fi

if [ "$copilot_should_install" = true ]; then
  if [ -f "$SRC/.github/copilot-instructions.md" ]; then
    # Check if any installed category is covered by copilot instructions
    # The copilot instructions file covers: ef, async, layering, errors, di, configuration, nullability, testing, performance, security, time, disposal, logging, concurrency, background, serialization, http, domain, ef-transactions
    # For simplicity, we'll install it if any category is being installed
    # Users can use --skip to exclude specific categories, but the copilot file is comprehensive
    relative_path=".github/copilot-instructions.md"
    install_with_backup "$SRC/.github/copilot-instructions.md" "$TARGET/.github/copilot-instructions.md" "copilot" "$relative_path"
  fi
fi

# --- Write manifest file ---
if [ -n "$MANIFEST_CONTENT" ]; then
  MANIFEST_FILE="$TARGET/.claude/skills/.dotnet-senior-skills-manifest"
  echo "$MANIFEST_CONTENT" | sed '/^$/d' > "$MANIFEST_FILE"
fi

# --- Summary ---
echo "Installation successful!" >&2
echo "Installed components:" >&2

# Always show skills count if any were installed
if [ $SKILLS_INSTALLED -gt 0 ]; then
  echo " - Claude Code skills: $SKILLS_INSTALLED" >&2
fi

# Show cursor rules only if they were installed
if [ $CURSOR_RULES_INSTALLED -gt 0 ]; then
  echo " - Cursor rules: $CURSOR_RULES_INSTALLED" >&2
fi

# Show copilot instructions only if they were installed
if [ $COPILOT_INSTRUCTIONS_INSTALLED -gt 0 ]; then
  echo " - Copilot instructions: $COPILOT_INSTRUCTIONS_INSTALLED" >&2
  echo " - Windsurf rules: $WINDSURF_RULES_INSTALLED" >&2  echo " - Cline rules: $CLINE_RULES_INSTALLED" >&2  echo " - AGENTS.md: $AGENTS_MD_INSTALLED" >&2
fi

# Show filter information if filters were used
if [ -n "$ONLY_CATEGORIES" ]; then
  echo " - AGENTS.md: $AGENTS_MD_INSTALLED" >&2
elif [ -n "$SKIP_CATEGORIES" ]; then
  echo " - Filter: --skip $SKIP_CATEGORIES" >&2
fi

if [ -n "$TOOLS" ]; then
  echo " - Tools: $TOOLS" >&2
fi

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

# --- Install AGENTS.md ---
# Install AGENTS.md only if agents tool is requested or no --tools filter is specified
agents_should_install=true

if [ -n "$TOOLS" ]; then
  # Check if agents tool is requested
  agents_requested=false
  for tool in $(echo "$TOOLS" | tr ',' ' '); do
    if [ "$tool" = "agents" ]; then
      agents_requested=true
      break
    fi
  done

  if [ "$agents_requested" = false ]; then
    agents_should_install=false
    echo "Skipping AGENTS.md installation (not requested via --tools)" >&2
  fi
fi

if [ "$agents_should_install" = true ]; then
  if [ -f "$SRC/AGENTS.md" ]; then
    relative_path="AGENTS.md"
    install_with_backup "$SRC/AGENTS.md" "$TARGET/AGENTS.md" "agents" "$relative_path"
  fi
fi

# --- Install Windsurf rules ---
# Install Windsurf rules only if windsurf tool is requested or no --tools filter is specified
windsurf_should_install=true

if [ -n "$TOOLS" ]; then
  # Check if windsurf tool is requested
  windsurf_requested=false
  for tool in $(echo "$TOOLS" | tr ',' ' '); do
    if [ "$tool" = "windsurf" ]; then
      windsurf_requested=true
      break
    fi
  done

  if [ "$windsurf_requested" = false ]; then
    windsurf_should_install=false
    echo "Skipping Windsurf rules installation (not requested via --tools)" >&2
  fi
fi

if [ "$windsurf_should_install" = true ]; then
  if [ -d "$SRC/.windsurfrules" ]; then
    # Copy all .md files from .windsurfrules directory
    while IFS= read -r rule_file; do
      if [ -f "$rule_file" ]; then
        # Extract relative path
        relative_path=".windsurfrules/$(basename "$rule_file")"
        install_with_backup "$rule_file" "$TARGET/.windsurfrules/$(basename "$rule_file")" "windsurf" "$relative_path"
      fi
    done < <(find "$SRC/.windsurfrules" -name "*.md" -type f)
  fi
fi

# --- Install Cline rules ---
# Install Cline rules only if cline tool is requested or no --tools filter is specified
cline_should_install=true

if [ -n "$TOOLS" ]; then
  # Check if cline tool is requested
  cline_requested=false
  for tool in $(echo "$TOOLS" | tr ',' ' '); do
    if [ "$tool" = "cline" ]; then
      cline_requested=true
      break
    fi
  done

  if [ "$cline_requested" = false ]; then
    cline_should_install=false
    echo "Skipping Cline rules installation (not requested via --tools)" >&2
  fi
fi

if [ "$cline_should_install" = true ]; then
  if [ -d "$SRC/.clinerules" ]; then
    # Copy all .clinerules files from .clinerules directory
    while IFS= read -r rule_file; do
      if [ -f "$rule_file" ]; then
        # Extract relative path
        relative_path=".clinerules/$(basename "$rule_file")"
        install_with_backup "$rule_file" "$TARGET/.clinerules/$(basename "$rule_file")" "cline" "$relative_path"
      fi
    done < <(find "$SRC/.clinerules" -name "*.clinerules" -type f)
  fi
fi
