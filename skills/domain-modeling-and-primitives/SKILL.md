---
name: domain-modeling-and-primitives
description: Review C# domain models - primitive obsession, value objects, records vs classes, enums vs polymorphism, invariant enforcement in constructors, and anemic model smells. Use when reviewing domain entities, value types, or business-logic placement.
---

# Domain Modeling and Primitives

## Primitive obsession: the threshold

A raw primitive is fine until it acquires rules or gets confused with its neighbors. The triggers for wrapping:
- Two same-typed parameters that must not be swapped: `Transfer(Guid fromAccountId, Guid toAccountId)` compiles happily with the arguments reversed. `AccountId` as a wrapped type turns the swap into a compile error.
- A validation rule enforced in more than one place: if `email` is regex-checked in the controller, the service, and the importer, the string should have been an `Email` type validating once, in its constructor.
- Money as `decimal`: adding EUR to USD compiles. `Money(decimal Amount, Currency Currency)` with an addition operator that throws on currency mismatch does not.

```csharp
// non-compiling: illustrative
// WRONG: every consumer re-validates or trusts blindly
public void Register(string email) { ... }
// RIGHT: an Email that exists is valid; the rule lives in one place
public readonly record struct Email
{
    public string Value { get; }
    public Email(string value)
    {
        if (!MailAddress.TryCreate(value, out _))
            throw new ArgumentException($"Invalid email: '{value}'", nameof(value));
        Value = value.Trim().ToLowerInvariant();
    }
    public override string ToString() => Value;
}
```

Do not wrap everything: a `PageNumber` type over an `int` used in one method is ceremony. The threshold is rules or confusability, not typing zeal. For EF mapping, value objects bind via `HasConversion`/`ComplexProperty` - "the ORM makes it hard" stopped being true years ago.

## Invariants live in constructors, not validators

An object that can exist in an invalid state forces every consumer to re-check it. Constructors (or factory methods, when creation can fail as a domain outcome) reject invalid states; from then on the type is proof.

- Public parameterless constructor + settable properties on a domain entity means the invariant is enforced nowhere. EF needs a private parameterless constructor at most; it does not need public setters (it sets backing fields).
- State transitions as methods, not property writes: `order.Ship(trackingNumber)` can enforce "only paid orders ship"; `order.Status = Shipped` cannot. A `Status` setter that any layer can write is where impossible states come from.
- Collections: expose `IReadOnlyCollection<OrderLine>` over a private list, mutate via `AddLine(...)` which enforces the rules. A public `List<T>` property is an invariant with a side door.

## Records: value semantics, not a class shorthand

- `record` for value objects and DTOs: equality by content is the point. `with` expressions give non-destructive mutation.
- Entities (things with identity and a lifecycle) are classes: two `Order` instances with the same data are not the same order, and record equality over a changing object is a trap - a record used as a dictionary key and then mutated via `with`-free property init misdirection is a lost key.
- Records with mutable properties (`set` instead of `init`) discard the guarantees while keeping the syntax - review flag.
- `readonly record struct` for small (< ~24 bytes) high-volume value objects (ids, quantities); reference records otherwise. Watch default-struct bypass: `default(Email)` skips your constructor - guard `Value` access or accept that empty means invalid downstream.

## Enums vs polymorphism

An enum plus one `switch` is fine - use exhaustive switch expressions (no `default` arm on domain enums, so a new member breaks compilation at every decision point instead of falling through silently). An enum plus the same `switch` in three places is dispatch you are hand-rolling: move the behavior onto the type (polymorphism or a strategy map). See the SOLID skill: name the cost, not the pattern.

Also: never persist enums by their numeric value into external contracts (see serialization skill), and `Enum.IsDefined` incoming values from clients - `(OrderStatus)42` casts without error.

## Anemic model: the honest assessment

All-getters-setters entities plus services that implement every rule is a valid architecture choice at CRUD complexity - do not flag it there. It becomes a defect at the point where the same business rule appears in two services, or where "what states can an Order be in" cannot be answered from the Order type. That is the review moment to push logic into the model - retrofit the specific rule being duplicated, not a wholesale DDD rewrite.

## Modeling review flags

- `bool` parameters changing method behavior (`Process(order, true)`) - unreadable at the call site; two methods or an options type.
- Nullable property pairs encoding a hidden state machine (`ShippedAt != null` means shipped): the state enum exists, write it down.
- Half the properties null in each state: two types being forced into one (see discriminated hierarchy in serialization skill).
- `DateTime`/`string` doing a domain type's job across a public API boundary: ids as `string` accept anything; typed ids accept ids.
