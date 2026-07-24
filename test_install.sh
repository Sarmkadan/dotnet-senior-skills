#!/usr/bin/env bash
# Test harness for ./install.sh
# Verifies idempotency, handling of missing directories, spaces in paths,
# and behavior when user‑authored skill files already exist.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

error() {
  echo "ERROR: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-}"
  if [[ "$expected" != "$actual" ]]; then
    echo "ASSERTION FAILED: $msg (expected: '$expected', got: '$actual')" >&2
    exit 1
  fi
}

run_install() {
  local target_dir="$1"
  shift
  local args=("$@")
  "./install.sh" "${args[@]}" "$target_dir"
  echo $?
}

# ---------------------------------------------------------------------------
# 1. Idempotency – run install twice without --force
# ---------------------------------------------------------------------------

tmp_target=$(mktemp -d)
mkdir -p "$tmp_target/.git"   # satisfy validation (git repo)

echo "=== Test 1: first install (should succeed) ==="
code=$(run_install "$tmp_target")
assert_eq 0 "$code" "first install exit code"

manifest1="$tmp_target/.claude/skills/.dotnet-senior-skills-manifest"
if [[ ! -f "$manifest1" ]]; then
  error "Manifest not created on first install"
fi
manifest_content1=$(cat "$manifest1")

echo "=== Test 1: second install (should fail, no duplicate) ==="
code=$(run_install "$tmp_target")
assert_eq 1 "$code" "second install exit code (expected failure due to existing manifest)"

manifest2="$tmp_target/.claude/skills/.dotnet-senior-skills-manifest"
manifest_content2=$(cat "$manifest2")
assert_eq "$manifest_content1" "$manifest_content2" "manifest unchanged after second run"

# ---------------------------------------------------------------------------
# 2. Missing target directory – should error clearly
# ---------------------------------------------------------------------------

nonexistent_target="/tmp/does-not-exist-$(date +%s)"
echo "=== Test 2: install to non‑existent directory (should error) ==="
if code=$(run_install "$nonexistent_target" 2>/dev/null); then
  error "install.sh succeeded on a non‑existent target"
else
  # Expected non‑zero exit; nothing else to check
  echo "Got expected failure (exit code $?)"
fi

# ---------------------------------------------------------------------------
# 3. Path containing spaces – must not break
# ---------------------------------------------------------------------------

tmp_with_spaces=$(mktemp -d)
spaced_dir="${tmp_with_spaces}/my project with spaces"
mkdir -p "$spaced_dir/.git"
echo "=== Test 3: install into path with spaces ==="
code=$(run_install "$spaced_dir")
assert_eq 0 "$code" "install into spaced path exit code"

# Verify a skill file was copied
skill_file="$spaced_dir/.claude/skills/async-await-pitfalls/SKILL.md"
if [[ ! -f "$skill_file" ]]; then
  error "Skill file not found in spaced path"
fi

# ---------------------------------------------------------------------------
# 4. User‑authored skill file – should not be overwritten without --force
# ---------------------------------------------------------------------------

# Modify a skill file after first install
user_skill_dir="$tmp_target/.claude/skills/async-await-pitfalls"
user_skill_file="$user_skill_dir/SKILL.md"
if [[ ! -f "$user_skill_file" ]]; then
  error "Expected skill file missing for user‑authored test"
fi
echo "// user modification" >> "$user_skill_file"

# Capture hash before re‑install
hash_before=$(sha256sum "$user_skill_file" | awk '{print $1}')

echo "=== Test 4: reinstall without --force (should skip modified file) ==="
code=$(run_install "$tmp_target")
assert_eq 1 "$code" "reinstall without --force should exit with error due to manifest"

# Hash should be unchanged
hash_after=$(sha256sum "$user_skill_file" | awk '{print $1}')
assert_eq "$hash_before" "$hash_after" "user‑modified skill file unchanged"

# ---------------------------------------------------------------------------
# 5. Reinstall with --force – should overwrite modified file
# ---------------------------------------------------------------------------

echo "=== Test 5: reinstall with --force (should overwrite) ==="
code=$(run_install --force "$tmp_target")
assert_eq 0 "$code" "reinstall with --force exit code"

hash_new=$(sha256sum "$user_skill_file" | awk '{print $1}')
if [[ "$hash_before" == "$hash_new" ]]; then
  error "File was not overwritten despite --force"
fi

echo "All tests passed."
