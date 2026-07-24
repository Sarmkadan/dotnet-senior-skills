#!/usr/bin/env bash
set -euo pipefail

# Generate README skill table from skill frontmatter
# This script reads each skill's SKILL.md file and generates a markdown table
# The table is written between marker comments in README.md

SKILLS_DIR="$(dirname "$0")/../skills"
README_FILE="$(dirname "$0")/../README.md"

# Check if skills directory exists
if [ ! -d "$SKILLS_DIR" ]; then
  echo "ERROR: Skills directory not found at $SKILLS_DIR" >&2
  exit 1
fi

# Check if README file exists
if [ ! -f "$README_FILE" ]; then
  echo "ERROR: README.md not found at $README_FILE" >&2
  exit 1
fi

# Create temporary file for new table
temp_table=$(mktemp)

# Write header to temp file
cat > "$temp_table" << 'EOF'
## Skills

| Skill | Covers |
| --- | --- |
EOF


# Find all SKILL.md files and process them
skill_files=$(find "$SKILLS_DIR" -name "SKILL.md" -type f | sort)

if [ -z "$skill_files" ]; then
  echo "ERROR: No SKILL.md files found in $SKILLS_DIR" >&2
  rm -f "$temp_table"
  exit 1
fi

# Process each skill file
for skill_file in $skill_files; do
  # Extract frontmatter
  if ! grep -q "^name:" "$skill_file"; then
    echo "ERROR: Missing 'name:' field in $skill_file" >&2
    rm -f "$temp_table"
    exit 1
  fi

  if ! grep -q "^description:" "$skill_file"; then
    echo "ERROR: Missing 'description:' field in $skill_file" >&2
    rm -f "$temp_table"
    exit 1
  fi

  # Extract name
  name=$(grep "^name:" "$skill_file" | sed 's/^name:[[:space:]]*//' | tr -d '"' | sed 's/[[:space:]]*$//' | head -1)

  # Validate name is not empty
  if [ -z "$name" ]; then
    echo "ERROR: Empty name field in $skill_file" >&2
    rm -f "$temp_table"
    exit 1
  fi

  # Extract description (value after description: on the same line)
  description=$(grep "^description:" "$skill_file" | sed 's/^description:[[:space:]]*//' | sed 's/[[:space:]]*$//' | head -1)

  # Validate description is not empty
  if [ -z "$description" ]; then
    echo "ERROR: Empty description field in $skill_file" >&2
    rm -f "$temp_table"
    exit 1
  fi

  # Escape pipe characters in description for markdown table
  description_escaped=$(echo "$description" | sed 's/|/\\\\|/g')


  # Get relative path for link
  rel_path=$(echo "$skill_file" | sed "s|^$SKILLS_DIR/||" | sed 's|/SKILL.md$||')


  # Write to temp file
  echo "| [$name](skills/$rel_path/SKILL.md) | $description_escaped |" >> "$temp_table"
done

# Check if we need to update README
# Extract the current table from README (between ## Skills and ## Sample rules)
current_table=$(mktemp)
sed -n '/^## Skills$/,/^## Sample rules$/p' "$README_FILE" | head -n -1 > "$current_table"

if cmp -s "$temp_table" "$current_table"; then
  echo "README table is up to date"
  rm -f "$temp_table" "$current_table"
  exit 0
else
  echo "Updating README table..."

  # Create new README with updated table
  temp_readme=$(mktemp)

  # Check if markers exist in README
  if grep -q "^## Skills$" "$README_FILE" && grep -q "^## Sample rules$" "$README_FILE"; then
    # Markers exist: replace the table between them
    sed -n '1,/^## Skills[[:space:]]*$/p' "$README_FILE" | head -n -1 > "$temp_readme"
    cat "$temp_table" >> "$temp_readme"
    sed -n '/^## Sample rules$/,$p' "$README_FILE" >> "$temp_readme"
  else
    # Markers don't exist: insert the table after "## Skills" header
    skills_line=$(grep -n "^## Skills$" "$README_FILE" | cut -d: -f1)

    if [ -n "$skills_line" ]; then
      # Insert table after "## Skills" header
      head -n "$skills_line" "$README_FILE" > "$temp_readme"
      cat "$temp_table" >> "$temp_readme"
      tail -n +$((skills_line + 1)) "$README_FILE" >> "$temp_readme"
    else
      # If no "## Skills" found, append at the end
      cat "$README_FILE" > "$temp_readme"
      echo "" >> "$temp_readme"
      cat "$temp_table" >> "$temp_readme"
    fi
  fi

  # Replace README with new version
  mv "$temp_readme" "$README_FILE"

  echo "✓ README table updated successfully"
  rm -f "$temp_table" "$current_table"
  exit 0
fi
