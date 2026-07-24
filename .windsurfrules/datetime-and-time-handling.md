# datetime-and-time-handling

Review .NET date/time code - DateTime vs DateTimeOffset, UTC discipline, TimeProvider for testability, timezone conversion, and scheduling pitfalls. Also covers culture-aware parsing/formatting of date/time values. Use when reviewing any code that touches DateTime, DateTimeOffset, timestamps, scheduling, or culture-sensitive date/time operations.

**See also:** globalization-and-culture for culture-sensitive parsing/formatting rules and string comparison guidelines.

## DateTimeOffset by default

`DateTime` carries a `Kind` flag that nothing enforces: a `Kind.Unspecified` value round-tripped through JSON, a database, or `ToLocalTime()` silently reinterprets the same ticks as a different instant. `DateTimeOffset` carries the offset in the value - comparisons and serialization are unambiguous.

```csharp
// non-compiling: illustrative
// WRONG: is this UTC? Local? Depends on who wrote it and which driver read it back.
public DateTime CreatedAt { get; set; }
// RIGHT
public DateTimeOffset CreatedAt { get; set; }
```

Decision table:
- **Instants** (created-at, expires-at, audit, logs, tokens): `DateTimeOffset`, stored as UTC. This is 90% of fields.
- **Calendar dates** (birthday, invoice date, holiday): `DateOnly`. A birthday has no timezone; storing it as midnight `DateTime` shifts it a day for half the planet.
- **Wall-clock times** (store opening hours): `TimeOnly` plus a timezone id stored separately.
- **Future local events** (a meeting at "10:00 Sofia time" next March): store local time + IANA timezone id, convert at read time. Pre-converting to UTC bakes in today's offset rules; a DST law change makes the stored instant wrong.

Review flag: `DateTime.Now` anywhere in server code. Server-local time depends on the box's timezone; two instances in different regions disagree. `DateTime.UtcNow` is acceptable in legacy code; new code uses `DateTimeOffset.UtcNow` - via `TimeProvider` (below).

## TimeProvider: the clock is a dependency

Any logic that branches on "now" (expiry, grace periods, business-day rules) is untestable when it calls the static clock. .NET 8+ ships `TimeProvider`; inject it, register `TimeProvider.System`, and use `FakeTimeProvider` (Microsoft.Extensions.TimeProvider.Testing) in tests.

```csharp
// non-compiling: illustrative
// WRONG: the test for "expires after 30 days" needs Thread.Sleep or a real month
if (DateTimeOffset.UtcNow > order.CreatedAt.AddDays(30)) { ... }
// RIGHT
public OrderService(TimeProvider clock) => _clock = clock;
if (_clock.GetUtcNow() > order.CreatedAt.AddDays(30)) { ... }
```

Multiple `UtcNow` reads inside one operation is a subtler bug: the value changes between reads, so "created" and "modified" timestamps of the same write differ. Read once at the top, pass the value down.

## Timezone conversion

- Convert at the presentation edge only. Storage, domain logic, and comparisons operate in UTC; the user's timezone applies exactly once, on display or on parsing user input.
- Use IANA ids (`Europe/Sofia`) - `TimeZoneInfo.FindSystemTimeZoneById` accepts them cross-platform since .NET 8. Windows ids (`FYRO Macedonia Standard Time`) in config are a portability bug.
- Never do arithmetic on local times: `localTime.AddHours(24)` across a DST transition is not "same time tomorrow". Convert to UTC, add, convert back - or use the date component and reattach the wall-clock time.
- `TimeZoneInfo.ConvertTime` on an ambiguous/invalid local time (the DST fold and gap) picks an answer silently. Code parsing user-supplied local times around 2-3 a.m. must decide policy explicitly (`IsAmbiguousTime`/`IsInvalidTime`).

## Durations and scheduling

- Elapsed time measurement: `Stopwatch` (or `TimeProvider.GetTimestamp()`/`GetElapsedTime`), never subtracting two `DateTime.Now` reads - the wall clock jumps on NTP sync, producing negative or hour-long "durations".
- `TimeSpan` for durations in APIs and options, not `int timeoutSeconds` - `TimeSpan.FromSeconds(30)` reads unambiguously, and misread units (ms vs s) are a classic 1000x incident.
- Recurring jobs defined as "daily at 02:30" in a DST-observing zone either skip or double-fire once a year. Schedule in UTC, or use a scheduler (Quartz, Hangfire) that has an explicit DST policy - not a hand-rolled `Task.Delay` loop computing the next local occurrence.

## Persistence and serialization flags

- SQL Server: `datetimeoffset` column for `DateTimeOffset`, `datetime2` never plain `datetime` (1753 floor, 3ms precision). PostgreSQL + Npgsql: `timestamp with time zone` stores UTC and Npgsql 6+ throws on non-UTC `DateTime` values - the exception is telling you a `Kind` bug exists upstream; fix the source, do not `SpecifyKind` at the call site.
- JSON: `System.Text.Json` emits ISO 8601. A client sending `"2026-07-17T10:00:00"` (no offset) deserializes into `Kind.Unspecified` - reject offset-less timestamps at the API contract level for instant fields.
- Unix epoch interop (`ToUnixTimeSeconds`) is always UTC by definition; a conversion helper that touches `TimeZoneInfo` on the way to epoch seconds is wrong.
