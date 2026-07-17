---
name: globalization-and-culture
description: Review .NET culture-sensitivity bugs - parsing and formatting with invariant vs current culture, string comparison choices, the Turkish-I problem, and localization boundaries. Use when reviewing Parse/ToString/string comparison code or anything formatting numbers and dates.
---

# Globalization and Culture

## The default is a landmine

`double.Parse`, `decimal.ToString`, `DateTime.Parse`, `string.Format`, and interpolation all default to `CultureInfo.CurrentCulture` - the culture of the thread, which in a server means "whatever the OS image or a stray configuration set". Code that works on the developer's en-US machine and corrupts data on a de-DE server:

```csharp
// WRONG: on a German-culture server, "1.5" parses as 15 (dot is a thousands separator)
var price = decimal.Parse(priceText);
// WRONG: emits "1,5" into a CSV/JSON/SQL string that expects "1.5"
var s = price.ToString();
// RIGHT: machine-to-machine data is invariant, always
var price = decimal.Parse(priceText, CultureInfo.InvariantCulture);
var s = price.ToString(CultureInfo.InvariantCulture);
```

The dividing rule: **data crossing a machine boundary** (files, protocols, URLs, database strings, config, logs meant for parsing) is `InvariantCulture`; **text rendered for a human eye** is the user's culture - explicitly resolved, not whatever the thread has. Any Parse/ToString/Format of numbers or dates with no `IFormatProvider` argument is a review question; enable CA1305 (specify IFormatProvider) as at least a warning to make the omissions visible.

Interpolated strings crossing machine boundaries: `FormattableString.Invariant($"page={page}&price={price}")` or `string.Create(CultureInfo.InvariantCulture, $"...")` - a bare `$"..."` building a URL formats the decimal with the thread culture.

## String comparison: say what you mean

Every comparison picks a `StringComparison`, and the unstated default differs by API - `==`/`Equals` are ordinal, but `string.Compare`, `CompareTo`, `IndexOf(string)`, `StartsWith(string)`, `EndsWith(string)` are **culture-sensitive** by default. That inconsistency is the bug generator: `list.Sort()` on strings and `s.StartsWith(prefix)` both behave differently per server culture.

- Identifiers, keys, headers, protocol tokens, file paths, anything a machine consumes: `StringComparison.Ordinal` / `OrdinalIgnoreCase`. This is 95% of server-side comparisons.
- Human-facing sorting/searching (a customer list ordered for display): `StringComparison.CurrentCulture` with the user's culture explicitly set - a deliberate, commented choice.
- `ToLower()`/`ToUpper()` for comparison purposes is always wrong twice: allocates, and uses current culture. `string.Equals(a, b, OrdinalIgnoreCase)` or an `OrdinalIgnoreCase` comparer on the collection (see collections skill).

The Turkish-I is the concrete failure: in tr-TR, `"INSERT".ToLower()` is `"ınsert"` (dotless ı), so `command.ToLower() == "insert"` fails, and security checks normalizing case with culture-sensitive lowering have produced real bypasses (`"ADMIN"` != `"admin"` checks defeated). Casing for comparison uses `OrdinalIgnoreCase` comparison, not pre-lowering; casing for storage normalization uses `ToLowerInvariant()`.

## Server culture discipline

- Do not set `Thread.CurrentThread.CurrentCulture` per request as an ambient side channel for formatting; it leaks across awaits into pooled threads' unrelated work only if set wrong (it flows with ExecutionContext - the real issue is that ambient state hides the dependency). Pass the resolved `CultureInfo` explicitly to the formatting seam, or use ASP.NET Core `RequestLocalization` middleware where the culture legitimately drives the response.
- `InvariantGlobalization` (`<InvariantGlobalization>true</InvariantGlobalization>`) for pure-API services with no human-facing formatting: smaller images, no ICU dependency, and every culture-sensitive call now behaves invariantly - which also converts hidden culture bugs into consistent behavior. Turning it on with existing `CurrentCulture` sorting is a behavior change; audit first.
- Docker note: default images may lack ICU (`Globalization.Invariant` mode silently on via the runtime image) - code assuming culture-aware behavior gets invariant instead, without an exception unless configured. Decide the mode explicitly in the csproj, not by base-image accident.

## Localization boundaries

- Exception messages, log templates, and internal errors: English, invariant, never localized - logs get grepped, not read by end users. User-visible text is translated at the presentation edge from resource keys; a domain layer throwing localized exception messages has mixed presentation into domain.
- Error codes over prose across the API boundary (exception skill) - the frontend localizes `order_out_of_stock`; it cannot localize a server-composed English sentence.
- Dates/numbers rendered client-side (JS `Intl`, mobile) beat server-side rendering into strings - ship ISO 8601 and raw numbers in the payload, format at the glass (see serialization skill).
