# Cursor .mdc Rules Glob/Trigger Scoping Audit

## Summary

This document summarizes the improvements made to Cursor .mdc rule glob/trigger scoping across all 25 rules in the repository.

## Problem Statement

The original implementation had several issues:

1. **Overly broad glob patterns**: Many rules used `**/*.cs` which caused them to trigger on every C# file, leading to context bloat and reduced effectiveness
2. **Inconsistent `alwaysApply` settings**: Some rules had `alwaysApply: false` while others were missing it
3. **EF Core rules not properly scoped**: Multiple EF Core-related rules all used `**/*.cs` instead of targeting DbContext-heavy files
4. **Middleware rules too broad**: Middleware rule targeted all `.cs` files instead of focusing on Program.cs/Startup.cs
5. **Globalization rule too broad**: Culture-related issues can occur anywhere, so this one appropriately kept `**/*.cs`

## Changes Made

### 1. EF Core Rules (3 files)

#### Before:
- `ef-core-query-review.mdc`: `globs: **/*.cs`
- `ef-core-transactions-and-concurrency.mdc`: `globs: **/*.cs`
- `ef-core-migration-safety.mdc`: `globs: **/Migrations/**/*.cs,**/*DbContext*.cs` ✅ (already correct)

#### After:
- `ef-core-query-review.mdc`: `globs: **/*DbContext*.cs,**/Migrations/**/*.cs,**/*Context*.cs,**/*Repository*.cs`
- `ef-core-transactions-and-concurrency.mdc`: `globs: **/*DbContext*.cs,**/*Context*.cs,**/*Repository*.cs,**/Migrations/**/*.cs`
- `ef-core-migration-safety.mdc`: `globs: **/Migrations/**/*.cs,**/*DbContext*.cs` ✅ (unchanged)

**Rationale**: EF Core-specific rules should only trigger on files that are likely to contain EF Core code:
- Files with "DbContext" or "Context" in the name
- Files in Migrations folders
- Repository files that typically use DbContext

### 2. Middleware Rule

#### Before:
- `middleware-and-pipeline-order.mdc`: `globs: **/*.cs`

#### After:
- `middleware-and-pipeline-order.mdc`: `globs: **/Program.cs,**/Startup.cs,**/*WebApplication*.cs,**/*AppBuilder*.cs`

**Rationale**: Middleware and pipeline configuration is primarily defined in:
- Program.cs (top-level statements)
- Startup.cs (traditional setup)
- WebApplication builder patterns
- Custom AppBuilder classes

### 3. HTTP Client Rule

#### Before:
- `http-resilience-and-outbound-calls.mdc`: `globs: **/*.cs`

#### After:
- `http-resilience-and-outbound-calls.mdc`: `globs: **/*HttpClient*.cs,**/*RestClient*.cs,**/*ServiceClient*.cs`

**Rationale**: Outbound HTTP calls are typically made through:
- HttpClient classes
- RestClient classes
- ServiceClient classes

### 4. Background Services Rule

#### Before:
- `background-work-and-hosted-services.mdc`: `globs: **/*.cs`

#### After:
- `background-work-and-hosted-services.mdc`: `globs: **/*BackgroundService*.cs,**/*HostedService*.cs,**/Program.cs,**/Startup.cs`

**Rationale**: Background processing code is typically in:
- BackgroundService classes
- HostedService classes
- Program.cs/Startup.cs where services are registered

### 5. Security Review Rule

#### Before:
- `security-review-dotnet.mdc`: `globs: **/*.cs`

#### After:
- `security-review-dotnet.mdc`: `globs: **/*Controller*.cs,**/*Endpoint*.cs,**/*Service*.cs`

**Rationale**: Security issues are most relevant in:
- Controller classes (API endpoints)
- Endpoint classes
- Service classes that handle business logic

### 6. API Layer Boundaries Rule

#### Before:
- `api-layer-boundaries.mdc`: `globs: **/*Controller*.cs,**/*Service*.cs,**/*Repository*.cs,**/*Endpoint*.cs` ✅ (already correct)

#### After:
- `api-layer-boundaries.mdc`: `globs: **/*Controller*.cs,**/*Service*.cs,**/*Repository*.cs,**/*Endpoint*.cs` ✅ (unchanged)

### 7. Configuration and Secrets Rule

#### Before:
- `configuration-and-secrets.mdc`: `globs: **/appsettings*.json,**/Program.cs,**/*Options*.cs` ✅ (already correct)

#### After:
- `configuration-and-secrets.mdc`: `globs: **/appsettings*.json,**/Program.cs,**/*Options*.cs` ✅ (unchanged)

### 8. Dependency Injection Rule

#### Before:
- `dependency-injection-lifetimes.mdc`: `globs: **/Program.cs,**/Startup.cs,**/*Extensions*.cs`

#### After:
- `dependency-injection-lifetimes.mdc`: `globs: **/Program.cs,**/Startup.cs,**/*Extensions*.cs` ✅ (already correct)

### 9. Testing Strategy Rule

#### Before:
- `testing-strategy.mdc`: `globs: **/*Tests*/**/*.cs,**/*Test*.cs` ✅ (already correct)

#### After:
- `testing-strategy.mdc`: `globs: **/*Tests*/**/*.cs,**/*Test*.cs` ✅ (unchanged)

## Rules That Keep `**/*.cs` Glob

The following rules appropriately use `**/*.cs` because the issues they address can occur in any C# file:


- `async-await-pitfalls.mdc` - Async issues can be anywhere
- `collections-and-equality.mdc` - Collections can be anywhere
- `concurrency-and-shared-state.mdc` - Concurrency issues can be anywhere
- `datetime-and-time-handling.mdc` - DateTime issues can be anywhere
- `disposal-and-resource-lifetime.mdc` - Disposal can be anywhere
- `domain-modeling-and-primitives.mdc` - Domain modeling can be anywhere
- `exception-and-result-strategy.mdc` - Exceptions can be anywhere
- `globalization-and-culture.mdc` - Culture issues can be anywhere
- `logging-and-observability.mdc` - Logging can be anywhere
- `memory-leaks-and-diagnostics.mdc` - Memory leaks can be anywhere
- `nullable-reference-discipline.mdc` - Nullable issues can be anywhere
- `performance-review.mdc` - Performance issues can be anywhere
- `serialization-review.mdc` - Serialization can be anywhere
- `solid-review-checklist.mdc` - SOLID principles can be anywhere

## `alwaysApply: false` Standardization

All 25 rules now have `alwaysApply: false` in their frontmatter to ensure they don't automatically apply to every file but only when relevant.

## Impact

### Before Changes:
- Rules with `**/*.cs` would trigger on every C# file
- Context bloat: Cursor would show suggestions for unrelated files
- Reduced effectiveness: Rules would fire even when not relevant

### After Changes:
- Rules only trigger on relevant files
- Reduced context bloat: Cursor shows suggestions only where needed
- Improved effectiveness: Rules are more focused and targeted
- Better developer experience: Less noise, more relevant suggestions

## Verification

All changes have been verified to:
1. Maintain proper YAML frontmatter structure
2. Keep the `alwaysApply: false` setting where appropriate
3. Use valid glob patterns
4. Not break any existing functionality
5. Comply with Cursor .mdc rule format requirements

## Files Modified

- `.cursor/rules/ef-core-query-review.mdc`
- `.cursor/rules/ef-core-transactions-and-concurrency.mdc`
- `.cursor/rules/middleware-and-pipeline-order.mdc`
- `.cursor/rules/http-resilience-and-outbound-calls.mdc`
- `.cursor/rules/background-work-and-hosted-services.mdc`
- `.cursor/rules/security-review-dotnet.mdc`
- `.cursor/rules/dependency-injection-lifetimes.mdc` (already correct)
- All other rules had `alwaysApply: false` added where missing
