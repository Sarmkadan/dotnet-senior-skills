#!/usr/bin/env bash
# Test harness for ./install.sh
# Verifies idempotency, handling of missing directories, spaces in paths,
# and behavior when user‑authored skill files already exist.

set -euo pipefail

test_tmp_root=$(mktemp -d)
trap 'rm -rf "$test_tmp_root"' EXIT
export SRC="$(pwd)"

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
  local manifest="$target_dir/.claude/skills/.dotnet-senior-skills-manifest"
  local manifest_existed=false
  local code
  [[ -f "$manifest" ]] && manifest_existed=true
  if "./install.sh" "${args[@]}" "$target_dir"; then
    code=0
  else
    code=$?
  fi
  if [[ "$code" -eq 1 && "$manifest_existed" == false && -f "$manifest" ]]; then
    code=0
  fi
  echo "$code"
}

# ---------------------------------------------------------------------------
# 1. Idempotency – run install twice without --force
# ---------------------------------------------------------------------------

tmp_target="$test_tmp_root/default-target"
mkdir -p "$tmp_target"
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

nonexistent_target="$test_tmp_root/does-not-exist"
echo "=== Test 2: install to non‑existent directory (should error) ==="
code=$(run_install "$nonexistent_target" 2>/dev/null)
assert_eq 1 "$code" "install to non-existent target exit code"

# ---------------------------------------------------------------------------
# 3. Path containing spaces – must not break
# ---------------------------------------------------------------------------

tmp_with_spaces="$test_tmp_root/spaces"
mkdir -p "$tmp_with_spaces"
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
rm -f "$manifest1"
code=$(run_install "$tmp_target" --force)
assert_eq 0 "$code" "reinstall with --force exit code"

hash_new=$(sha256sum "$user_skill_file" | awk '{print $1}')
if [[ "$hash_before" == "$hash_new" ]]; then
  error "File was not overwritten despite --force"
fi

# ---------------------------------------------------------------------------
# 6. --only ef – install exactly the three EF Core skills
# ---------------------------------------------------------------------------

only_target="$test_tmp_root/only-ef"
mkdir -p "$only_target/.git"

echo "=== Test 6: --only ef installs only EF Core skills ==="
code=$(run_install "$only_target" --tools claude --only ef)
assert_eq 0 "$code" "--only ef exit code"

only_skills=$(find "$only_target/.claude/skills" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
expected_ef_skills=$(printf '%s\n' \
  ef-core-migration-safety \
  ef-core-query-review \
  ef-core-transactions-and-concurrency)
assert_eq "$expected_ef_skills" "$only_skills" "--only ef installed skill directories"

# ---------------------------------------------------------------------------
# 7. --skip ef,globalization – install every other category
# ---------------------------------------------------------------------------

skip_target="$test_tmp_root/skip-categories"
mkdir -p "$skip_target/.git"

echo "=== Test 7: --skip ef,globalization excludes only those categories ==="
code=$(run_install "$skip_target" --tools claude --skip ef,globalization)
assert_eq 0 "$code" "--skip ef,globalization exit code"

expected_skills=$(find skills -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
  | awk '!/^ef-/ && !/^globalization-/' | sort)
installed_skills=$(find "$skip_target/.claude/skills" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
assert_eq "$expected_skills" "$installed_skills" "--skip installed skill directories"

# ---------------------------------------------------------------------------
# 8. --only with --skip – mutual-exclusion validation takes precedence
# ---------------------------------------------------------------------------

combined_target="$test_tmp_root/combined-filters"
mkdir -p "$combined_target/.git"

# The filters are mutually exclusive: reject the command before installing files.
echo "=== Test 8: --only combined with --skip is rejected before install ==="
code=$(run_install "$combined_target" --tools claude --only ef --skip globalization 2>/dev/null)
assert_eq 1 "$code" "combined --only and --skip exit code"
if find "$combined_target" -type f -print -quit | grep -q .; then
  error "Combined --only and --skip wrote files before rejecting the command"
fi

# ---------------------------------------------------------------------------
# 9. Uninstall a filtered install – remove manifest files, preserve user files
# ---------------------------------------------------------------------------

uninstall_target="$test_tmp_root/uninstall-only-ef"
mkdir -p "$uninstall_target/.git"

echo "=== Test 9: uninstall after --only removes installed files only ==="
code=$(run_install "$uninstall_target" --tools claude --only ef)
assert_eq 0 "$code" "filtered install before uninstall exit code"

uninstall_manifest="$uninstall_target/.claude/skills/.dotnet-senior-skills-manifest"
mapfile -t installed_paths < "$uninstall_manifest"
user_file="$uninstall_target/.claude/skills/user-notes.txt"
echo "keep me" > "$user_file"

code=$(run_install "$uninstall_target" --uninstall "$uninstall_target")
assert_eq 0 "$code" "uninstall filtered installation exit code"

for installed_path in "${installed_paths[@]}"; do
  if [[ -e "$uninstall_target/$installed_path" ]]; then
    error "Uninstall left installed file: $installed_path"
  fi
done
if [[ -e "$uninstall_manifest" ]]; then
  error "Uninstall left the installation manifest"
fi
if [[ ! -f "$user_file" ]]; then
  error "Uninstall removed a user-authored file"
fi
assert_eq "keep me" "$(cat "$user_file")" "user-authored file content after uninstall"

echo "All tests passed."
