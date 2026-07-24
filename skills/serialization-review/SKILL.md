---
name: serialization-review
description: Review .NET serialization - System.Text.Json configuration, contract evolution, polymorphism, streaming large payloads, and deserialization security. Use when reviewing JSON handling, serializer options, or API/message contracts.
---

# Serialization Review (.NET)

## One options instance, defined once

`JsonSerializerOptions` caches type metadata; a new instance per call rebuilds it every time - a real, measured hot-path cost. Define the codebase's options once (static readonly, or via `ConfigureHttpJsonOptions`/`AddJsonOptions` for ASP.NET Core) and reference it everywhere:

```csharp
// non-compiling: illustrative
// WRONG: metadata cache rebuilt per call, and settings drift per call site
return JsonSerializer.Serialize(dto, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
// RIGHT
public static class Json { public static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web); }
return JsonSerializer.Serialize(dto, Json.Web);
```

Two call sites with different casing policies for the same contract is a bug factory - the review flag is `new JsonSerializerOptions` anywhere outside composition/static init.

## Contracts evolve; plan for it in review

- Unknown incoming properties are silently dropped by default - good for forward compatibility, bad for security (see mass-assignment in the security skill) and for typo detection on internal contracts. For messages between your own services, `UnmappedMemberHandling = Disallow` turns silent contract drift into a loud failure.
- Renaming a property is a breaking change for every stored document and in-flight message, not just live callers. Additive evolution only: add the new property, keep reading the old one, migrate, then remove - the expand/contract pattern from the migrations skill applies to JSON too.
- Required fields: `required` properties / `JsonRequiredAttribute` make missing-field bugs fail at deserialization instead of as default-valued ghosts three layers later. A DTO where `Amount = 0` is indistinguishable from "amount was absent" will eventually charge someone zero.
- Enums: serialize as strings (`JsonStringEnumConverter`). Numeric enum wire values mean reordering the enum silently corrupts every stored payload; string values also survive adding members. Decide the unknown-value policy explicitly for incoming strings.

## Polymorphism without type-name injection

### UNSAFE: Reflection-based polymorphic deserialization

Never accept a type name from the payload to decide what to construct using reflection - that is the deserialization RCE class:

```csharp
// UNSAFE: Type.GetType() with user-supplied type name - RCE vector
var typeName = json["$type"]; // attacker-controlled
var type = Type.GetType(typeName); // arbitrary assembly loading
var instance = JsonSerializer.Deserialize(json, type); // RCE!

// UNSAFE: TypeNameHandling-style patterns ported from Newtonsoft habits
var options = new JsonSerializerOptions
{
    TypeInfoResolver = new DefaultJsonTypeInfoResolver() // allows arbitrary types
};
var result = JsonSerializer.Deserialize<BaseType>(json, options); // RCE!
```

These patterns enable arbitrary code execution (RCE) when deserializing untrusted input. An attacker can specify any .NET type from any assembly, including malicious types that execute code during construction.

### SAFE: Allow-listed polymorphic discriminators

System.Text.Json's allow-listed discriminators are the safe version:

```csharp
[JsonPolymorphic(TypeDiscriminatorPropertyName = "type")]
[JsonDerivedType(typeof(CardPayment), "card")]
[JsonDerivedType(typeof(BankTransfer), "bank")]
public abstract record Payment;

// SAFE: Closed set of known types only
var payment = JsonSerializer.Deserialize<Payment>(jsonWithTypeDiscriminator);
```

The discriminator maps to a closed set you declared; an unknown value fails. This is safe even for untrusted sources because it only materializes types you explicitly allow.

### Security Hard Rule

**Deserializing any type discriminator or `$type`-like field from untrusted (external API/user-supplied) JSON into a concrete .NET type MUST use an explicit allowlist of known types.** Never use:
- `Type.GetType(userSuppliedString)` or `Type.GetType(userSuppliedString, throwOnError: false)`
- Custom `JsonConverter` that switches types based on input
- `TypeNameHandling` patterns or similar reflection-based type resolution
- Unrestricted polymorphic converters

These are known RCE/gadget-chain vectors in .NET deserialization. Even when the source claims to be trusted, queues and databases are attacker-reachable in more incidents than anyone plans for.

### Before/After Example

```csharp
// BEFORE: UNSAFE - allows arbitrary type construction
public class PaymentService
{
    public object ProcessPayment(string json)
    {
        // Attacker can specify "System.IO.File, System.IO, Version=4.2.0.0" as $type
        // and execute arbitrary code during deserialization
        return JsonSerializer.Deserialize<object>(json);
    }
}

// AFTER: SAFE - closed set of allowed types
[JsonPolymorphic(TypeDiscriminatorPropertyName = "paymentMethod")]
[JsonDerivedType(typeof(CardPayment), "card")]
[JsonDerivedType(typeof(BankTransfer), "bank")]
[JsonDerivedType(typeof(DigitalWallet), "wallet")]
public abstract record Payment;

public class PaymentService
{
    public Payment ProcessPayment(string json)
    {
        // Only CardPayment, BankTransfer, or DigitalWallet can be constructed
        // Unknown paymentMethod values throw JsonException
        return JsonSerializer.Deserialize<Payment>(json);
    }
}
```

## Large payloads: stream, don't buffer

- `JsonSerializer.SerializeAsync(stream, ...)` / `DeserializeAsync<T>(stream, ...)` against the request/response body, not `Serialize` to a string first - a string round-trip doubles memory and lands multi-MB payloads on the LOH.
- Reading a huge array of items for per-item processing: `JsonSerializer.DeserializeAsyncEnumerable<T>(stream, ct)` processes elements as they arrive instead of materializing the whole list.
- `HttpClient`: `ReadFromJsonAsync<T>()` streams; `ReadAsStringAsync()` then `Deserialize` buffers - the former, always, and it also respects the charset header.
- Inbound size limits exist and are deliberate: unbounded request bodies deserialized into object graphs are a memory-exhaustion vector. Depth limits too (`MaxDepth`) when input is hostile - default 64 is fine, `0`/unbounded is not.

## Round-trip honesty

- `decimal` for money survives JSON as a number in .NET-to-.NET, but JavaScript callers read it as double and corrupt cents on large values; same for `long` ids above 2^53. Contracts consumed by JS serialize money and snowflake ids as strings.
- `DateTime` without offset in payloads: see the datetime skill - require offsets on instant fields at the contract level.
- Reference cycles (EF entities with navigations both ways) throw or emit `$ref` garbage - the actual fix is never `ReferenceHandler.Preserve`, it is "stop serializing entities" (api-layer skill).
- Dictionary keys, `TimeSpan`, `char`: check the actual emitted JSON in a test. Contract shape is asserted by at least one snapshot/approval test per public contract, so a serializer upgrade or attribute change fails CI instead of production consumers.

## Source generation

AOT, trimming, or measured startup/throughput needs: `JsonSerializerContext` source generation. Otherwise reflection mode is fine - source-gen everywhere by default adds build complexity without a driver. If source-gen is on, `JsonSourceGenerationMode.Metadata` + options mismatch bugs (attribute says camelCase, context says default) are the thing to review.
