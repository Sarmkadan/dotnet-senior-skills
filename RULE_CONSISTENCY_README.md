# Rule Format Consistency System

This directory contains tools to detect and prevent drift across three parallel rule-encoding formats:

## The Three Formats

### 1. Full Skills (`skills/*/SKILL.md`)
- **Purpose**: Canonical source of truth for each skill
- **Content**: Complete rules with detailed explanations, rationale, and multiple code examples
- **Format**: Markdown with frontmatter, organized by skill topic
- **Example**: `skills/serialization-review/SKILL.md`


### 2. Cursor Rules (`.cursor/rules/*.mdc`)
- **Purpose**: Cursor IDE rule format for inline code reviews
- **Content**: Mirrors the full skill content (should be identical to SKILL.md)
- **Format**: Cursor-specific .mdc format with frontmatter
- **Example**: `.cursor/rules/serialization-review.mdc`

### 3. Copilot Instructions (`.github/copilot-instructions.md`)
- **Purpose**: Condensed rules for GitHub Copilot inline suggestions
- **Content**: Minimal version with only essential rules (no detailed explanations)
- **Format**: Single markdown file with category headers
- **Example**: See `.github/copilot-instructions.md` sections

## The Drift Problem

When these three formats were added in separate commits:
1. Skills were added as full SKILL.md files
2. Then mirrored as Cursor .mdc files
3. Then condensed sections were added to copilot-instructions.md

The formats can silently diverge. For example:
- A hard threshold like "two or more collection Includes" stated precisely in SKILL.md
- Paraphrased loosely in the copilot condensed section
- A before/after C# example present in the .mdc file but dropped in the condensed version


## Detection Tools

### 1. Quick Consistency Check
```bash
python3 validate_rule_consistency.py
```

Checks all 13 skills and reports:
- Code example count mismatches across formats
- Detailed explanation presence mismatches
- Hard thresholds/exceptions present in only one format
- **Automatic reconciliation guidance** with quick fix commands


After running, you'll see specific commands to fix issues like:
```
📋 QUICK FIX COMMANDS:
  1. Update .mdc file:
     cp skills/serialization-review/SKILL.md .cursor/rules/serialization-review.mdc

  2. Update copilot section:
     vim .github/copilot-instructions.md
     # Add condensed version under appropriate category header

  3. Verify fix:
     python3 validate_rule_consistency.py
```

### 2. Detailed Consistency Report
```bash
python3 reconcile_rules.py report
```

Generates `rule_consistency_report.json` with:
- Line counts, code block counts, and file sizes for each format
- Summary statistics across all skills
- Detailed breakdown per skill
- Comprehensive data for analysis and CI integration


### 3. Manual Review Checklist
```bash
python3 reconcile_rules.py checklist
```

Generates a comprehensive checklist for maintaining consistency when making changes.

### 4. Reconciliation Workflow
```bash
# After detecting issues with validate_rule_consistency.py
# Fix .mdc files by copying from SKILL.md
cp skills/<skill-name>/SKILL.md .cursor/rules/<skill-name>.mdc

# Update copilot-instructions.md with condensed rules
vim .github/copilot-instructions.md

# Verify all formats are now consistent
python3 validate_rule_consistency.py
```

## Usage Workflow

### Before Making Changes
```bash
# Check current consistency
python3 validate_rule_consistency.py

# Generate detailed report
python3 reconcile_rules.py report
```

### When Adding/Changing a Rule

1. **Update SKILL.md** (canonical source)
```bash
vim skills/<skill-name>/SKILL.md
```
- Add comprehensive explanations
- Include code examples with BEFORE/AFTER patterns
- Document hard thresholds and exception types

2. **Update .mdc file** (mirror SKILL.md)
```bash
vim .cursor/rules/<skill-name>.mdc
```
- Keep the same content as SKILL.md
- Maintain identical structure and examples

3. **Update copilot-instructions.md** (condensed version)
```bash
vim .github/copilot-instructions.md
```
- Add condensed version under appropriate category header
- Keep only essential rules (remove detailed explanations)
- Preserve hard thresholds and exception types

4. **Verify consistency**
```bash
python3 validate_rule_consistency.py
python3 reconcile_rules.py report
```

### After Making Changes
```bash
# Final verification
python3 validate_rule_consistency.py

# Ensure all skills show "No consistency issues detected"

# Commit all three changed files together:
git add skills/<skill-name>/SKILL.md
.git add .cursor/rules/<skill-name>.mdc
.git add .github/copilot-instructions.md
git commit -m "chore: update <skill-name> rules across all formats"
```

## What to Check for Consistency

### Code Examples
- **SKILL.md**: Should have multiple code examples (BEFORE/AFTER patterns)
- **.mdc**: Should mirror SKILL.md exactly (same number of code blocks)
- **copilot**: May omit detailed examples, but should preserve **hard thresholds** and **exception types**

**Key Check**: All three formats should have the same number of ` ```csharp ` code blocks.

### Hard Thresholds & Exception Types
Look for patterns like:
- "two or more collection Includes"
- "2-3 attempts"
- "one use case = one SaveChanges"
- "OperationCanceledException"
- "DbUpdateConcurrencyException"
- "JsonException"
- "InvalidOperationException"

**All formats should mention the same thresholds/exceptions.**

The validation script automatically detects when a threshold exists in only one format:
```
⚠️  Hard threshold/exception 'JsonException' exists in only SKILL.md
   Action: Ensure 'JsonException' is mentioned in all three formats
```

### Detailed Explanations
- **SKILL.md**: Full explanations with rationale (typically >15 meaningful lines)
- **.mdc**: Should match SKILL.md exactly
- **copilot**: Condensed bullet points only (typically <15 meaningful lines)

### Before/After Examples
- **SKILL.md**: Should have clear BEFORE/AFTER patterns
- **.mdc**: Should mirror these examples
- **copilot**: May condense to a single rule statement

**Important**: The copilot format intentionally omits detailed examples, but it MUST preserve:
- Hard thresholds (e.g., "2-3 attempts", "one use case")
- Exception types (e.g., "OperationCanceledException")
- Critical rule statements

Example of what to preserve in copilot:
```markdown
## Background Work
- `ExecuteAsync` loops catch per iteration, filter `OperationCanceledException` on shutdown
- One `IServiceScope` per unit of work; honor `stoppingToken` at every await
- Queue consumers: ack after commit, idempotent handlers, bounded retry then dead-letter
```
Note: "OperationCanceledException" is preserved even though the detailed examples are omitted.

## Example: Updating the Serialization Skill

### Step 1: Update SKILL.md
```bash
vim skills/serialization-review/SKILL.md
```

Add a new rule about JsonSerializerOptions:
```markdown
## One shared options instance

`JsonSerializerOptions` caches type metadata; a new instance per call rebuilds it every time.

```csharp
// WRONG: metadata cache rebuilt per call
return JsonSerializer.Serialize(dto, new JsonSerializerOptions { ... });

// RIGHT: define once and reuse
public static class Json { public static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web); }
return JsonSerializer.Serialize(dto, Json.Web);
```
```

### Step 2: Update .mdc file
```bash
vim .cursor/rules/serialization-review.mdc
```

Mirror the same content:
```markdown
## One shared options instance

`JsonSerializerOptions` caches type metadata; a new instance per call rebuilds it every time.

```csharp
// WRONG: metadata cache rebuilt per call
return JsonSerializer.Serialize(dto, new JsonSerializerOptions { ... });

// RIGHT: define once and reuse
public static class Json { public static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web); }
return JsonSerializer.Serialize(dto, Json.Web);
```
```

### Step 3: Update copilot-instructions.md
```bash
vim .github/copilot-instructions.md
```

Add condensed version under "## Serialization" section:
```markdown
## Serialization
- One shared `JsonSerializerOptions` instance; `new JsonSerializerOptions` outside composition is a bug
- Enums as strings; `required` on mandatory contract fields
- Contract changes are additive; property renames break stored payloads
- Polymorphism via `[JsonPolymorphic]` allow-listed discriminators - never type names from input
- Stream large payloads, don't buffer strings; money and >2^53 ids as strings for JS consumers
```

### Step 4: Verify
```bash
python3 validate_rule_consistency.py
```

Should show:
```
Checking skill: serialization-review
--------------------------------------------------------------------------------
✓ No consistency issues detected
```

## Automated Checks in CI

The `validate_rule_consistency.py` script can be integrated into CI to prevent drift:

```yaml
# Example GitHub Actions workflow
name: Validate Rule Consistency
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - name: Install dependencies
        run: pip install -r requirements.txt
      - name: Validate rule consistency
        run: python3 validate_rule_consistency.py
        id: consistency-check
      - name: Fail on inconsistency
        if: steps.consistency-check.outcome != 'success'
        run: echo "Rule formats are inconsistent!" && exit 1
```

## Files in This Directory

- `validate_rule_consistency.py` - Main consistency check script with automatic reconciliation guidance
- `reconcile_rules.py` - Helper script for reports and checklists
- `rule_consistency_report.json` - Generated detailed report (after running `reconcile_rules.py report`)
- `RULE_CONSISTENCY_README.md` - This file

## Best Practices

### ✓ DO
- Keep SKILL.md as the canonical source
- Mirror SKILL.md exactly in .mdc files
- Condense thoughtfully for copilot-instructions.md
- Preserve hard thresholds and exception types in all formats
- Commit all three files together when making changes
- Run consistency checks before and after changes

### ✗ DON'T
- Update only one format and forget the others
- Remove hard thresholds when condensing for copilot
- Change examples in .mdc without changing SKILL.md
- Let formats diverge over time
- Assume the condensed format is "less important" - it's used by Copilot!

## Common Issues and Fixes

### Issue: Code example count mismatch between SKILL.md and .mdc
**Cause**: .mdc file wasn't properly mirrored from SKILL.md

**Fix**: Copy the code examples from SKILL.md to .mdc file

### Issue: Hard threshold only in SKILL.md
**Cause**: Threshold was added to SKILL.md but not condensed for copilot

**Fix**: Add the threshold to the copilot-instructions.md condensed section

### Issue: Exception type missing from copilot
**Cause**: Exception was added to SKILL.md but not to condensed format
**Fix**: Add the exception name to the copilot section

## Support

For questions or issues with rule consistency:
- Check this README first
- Run the consistency tools to identify issues
- Review the detailed report for specific discrepancies
- Follow the checklist when making changes
