#!/usr/bin/env bash
# Test script for the README table generator
set -euo pipefail

echo "=== Testing README Table Generator ==="
echo

# Test 1: Generator runs without errors
echo "Test 1: Generator executes successfully"
./scripts/gen-readme-table.sh
echo "✓ Test 1 passed"
echo

# Test 2: Generator exits with 0 when table is up to date
if ./scripts/gen-readme-table.sh >/dev/null 2>&1; then
  echo "✓ Test 2 passed: Generator exits with code 0 when table is up to date"
else
  echo "✗ Test 2 failed: Generator should exit with code 0 when table is up to date"
  exit 1
fi
echo

# Test 3: Generator updates table when README is modified
echo "Test 3: Generator updates outdated table"
cp README.md README.md.test_backup
# Simulate drift by removing the last skill entry from the table
if grep -q "| \[.*\](skills/" README.md; then
  # Remove the last skill line in the table
  sed -i '/^| \[.*\](skills\//,/^| --- | --- |/!b' README.md
  sed -i '/^| \[.*\](skills\//,$!b;/^| \[.*\](skills\//{:a;N;/^| --- | --- |/!ba;s/\n/\\n/;s/.*\n//}' README.md
fi
if ./scripts/gen-readme-table.sh >/dev/null 2>&1; then
  # Check that the table was regenerated (should have all skills now)
  skill_count=$(find skills -name "SKILL.md" | wc -l)
  table_count=$(grep -c "| \[.*\](skills/" README.md || true)
  if [ "$skill_count" -eq "$table_count" ]; then
    echo "✓ Test 3 passed: Generator updates outdated table"
  else
    echo "✗ Test 3 failed: Generator should have updated all skills"
    mv README.md.test_backup README.md
    exit 1
  fi
else
  echo "✗ Test 3 failed: Generator should update the table"
  mv README.md.test_backup README.md
  exit 1
fi
# Restore the correct table
mv README.md README.md.new && mv README.md.test_backup README.md
mv README.md.new README.md
echo

# Test 4: Generator validates all skill files have required frontmatter
echo "Test 4: Generator validates skill frontmatter"
missing_name=false
for skill in skills/*/SKILL.md; do
  if ! grep -q "^name:" "$skill"; then
    echo "✗ Test 4 failed: Missing name in $skill"
    missing_name=true
  fi
  if ! grep -q "^description:" "$skill"; then
    echo "✗ Test 4 failed: Missing description in $skill"
    missing_name=true
  fi
done
if [ "$missing_name" = false ]; then
  echo "✓ Test 4 passed: All skill files have required frontmatter"
else
  exit 1
fi
echo

# Test 5: Generator produces valid markdown table
echo "Test 5: Generator produces valid markdown table"
./scripts/gen-readme-table.sh
if grep -q "| Skill | Covers |" README.md && grep -q "| --- | --- |" README.md; then
  echo "✓ Test 5 passed: Table has correct markdown structure"
else
  echo "✗ Test 5 failed: Table structure is incorrect"
  exit 1
fi
echo

# Test 6: All skills are included in the table
echo "Test 6: All skills are included in the table"
skill_count=$(find skills -name "SKILL.md" | wc -l)
table_count=$(grep -c "| \[.*\](skills/" README.md || true)
if [ "$skill_count" -eq "$table_count" ]; then
  echo "✓ Test 6 passed: All $skill_count skills are in the table"
else
  echo "✗ Test 6 failed: Expected $skill_count skills, found $table_count in table"
  exit 1
fi
echo

echo "=== All Tests Passed! ==="
echo

echo "Summary:"
echo "- Generator script works correctly"
echo "- Updates README table from skill frontmatter"
echo "- Validates all skill files"
echo "- Produces valid markdown"
echo "- Includes all skills"
