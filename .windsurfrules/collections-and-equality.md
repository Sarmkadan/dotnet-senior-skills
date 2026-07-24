# collections-and-equality

Review .NET collection and equality code - choosing collection types, exposure through APIs, GetHashCode/Equals contracts, dictionary key safety, and comparer usage. Use when reviewing collection-typed members, equality implementations, or LINQ set operations.

## Return types: promise the least

- Public API returns: `IReadOnlyList<T>` / `IReadOnlyCollection<T>` for materialized data. Returning `List<T>` invites callers to mutate your internal state; returning `IEnumerable<T>` from a method that already has a list hides `Count` and invites re-enumeration paranoia (`.ToList()` calls sprinkled by nervous callers).
- Return `IEnumerable<T>` only when the sequence is genuinely lazy/streaming - and then the method name or docs say so, because every enumeration re-executes (the multiple-enumeration bug is in the performance skill; here the point is: do not create the ambiguity).
- Never return `null` for an empty collection: `Array.Empty<T>()` / `[]`. Every caller null-check on a collection return is a design apology.
- Parameters: accept the weakest thing you actually need - `IEnumerable<T>` if you only iterate once, `IReadOnlyCollection<T>` if you need `Count`. A parameter typed `List<T>` forces callers to copy.

## Exposed mutable collections

```csharp
// non-compiling: illustrative
// WRONG: any consumer can do order.Lines.Clear() - the invariant has a side door
public List<OrderLine> Lines { get; set; } = new();
// RIGHT: mutation goes through the method that enforces the rules
private readonly List<OrderLine> _lines = new();
public IReadOnlyCollection<OrderLine> Lines => _lines.AsReadOnly();
public void AddLine(OrderLine line) { /* rules */ _lines.Add(line); }
```

Note `AsReadOnly()` wraps (view of live list, cheap); `ToList()` in a getter copies per access - a `foreach` over a copying getter allocates once, but `order.Lines[i]` in a loop copies the entire list N times. Know which one you wrote.

## The Equals/GetHashCode contract

Equal objects must have equal hash codes, and the hash must not change while the object is in a hash-based collection. Violations do not throw - they make dictionary entries unfindable: `Add` succeeds, `TryGetValue` with an equal key returns false, `Remove` silently fails, counts drift.

- Override both or neither. `Equals` without `GetHashCode` compiles with a warning people suppress and breaks every `Distinct()`, `GroupBy()`, `HashSet`, and dictionary that touches the type.
- Implement via `IEquatable<T>` (avoids boxing in generic collections) and `HashCode.Combine(...)` - not hand-rolled XOR (collides symmetric values: `(a,b)` and `(b,a)` hash equal).
- Or don't implement at all: a `record` gets correct value equality generated. Hand-written equality on a type that could be a record is maintenance surface for zero gain - every added property must be added in three places or equality silently lies.
- **Mutable objects as dictionary/set keys**: the key's hash-relevant fields must never change post-insertion. A `HashSet<Item>` where `item.Name` (part of the hash) is later assigned = a corrupted set. Keys are immutable types - ids, strings, readonly record structs.

## Choosing the structure

- Lookup by key in any loop: `Dictionary`/`HashSet` built once, not `list.First(x => x.Id == id)` per iteration - that is O(n*m), the in-memory N+1 (performance skill), and it appears constantly in mapping code. `ToDictionary(x => x.Id)` before the loop.
- `ToLookup` for one-to-many grouping lookups; `GroupBy` when streaming groups once.
- `FrozenDictionary`/`FrozenSet` (.NET 8+) for build-once-read-forever singletons (config maps, routing tables) - faster reads than `Dictionary`, and the type documents the immutability.
- `ImmutableList` et al. are for shared-snapshot semantics (safe publication to concurrent readers), not a default - per-operation allocation makes them slower where nothing is shared.
- Struct enumeration: `List<T>` via `IEnumerable<T>` interface boxes its struct enumerator - iterate concrete types in hot loops (performance skill).

## String keys and comparers

Every hash structure keyed by strings states its comparer explicitly when case matters: `new Dictionary<string, T>(StringComparer.OrdinalIgnoreCase)`. Normalizing keys at insertion (`key.ToLowerInvariant()`) but not at lookup - or vice versa - is a bug the comparer makes impossible. Culture-sensitive comparers (`CurrentCulture`) in dictionaries: essentially never (see globalization skill); ordinal is the default for identifiers.

Same for LINQ set operators: `Distinct()`, `Except()`, `Contains()`, `GroupBy()` all take an `IEqualityComparer<T>` overload - flag any of them applied to strings or custom types where the intended equality is not the default one. `orders.Select(o => o.Email).Distinct()` deduplicates case-sensitively; if that is wrong, it is wrong silently.
