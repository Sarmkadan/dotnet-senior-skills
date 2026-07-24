# solid-review-checklist

Apply SOLID principles concretely to C# code review - real smells, thresholds, and refactors rather than abstract definitions. Use when reviewing class design, service structure, or interface changes in C#.

## Single Responsibility

Trigger questions: how many reasons does this class change for, and who asks for each change? Concrete smells:
- Constructor takes 6+ dependencies. That is 6 collaborators' worth of reasons to change; split the use cases.
- Method groups with disjoint dependency usage: if `ImportUsers` uses `_csv` and `_repo`, while `SendDigest` uses `_email` and `_clock`, you have two classes cohabiting.
- Names containing `Manager`, `Helper`, `Util`, `Processor` plus a 500-line body. The name is vague because the responsibility is.

Do not over-apply: a class with three methods around one aggregate is fine. SRP violations are proven by change history (this file appears in every PR), not by line count alone.

## Open/Closed

The practical form: adding a new case should not require editing a switch that already shipped. Trigger: the same `switch (type)` appears in 2+ places.

```csharp
// SMELL: every new export format edits this switch and its twin in ValidateFormat
public byte[] Export(string format) => format switch
{
    "csv" => ExportCsv(), "xlsx" => ExportXlsx(), _ => throw new NotSupportedException()
};
// REFACTOR: strategy resolved from DI
public interface IExporter { string Format { get; } byte[] Export(ReportData d); }
// registration: services.AddSingleton<IExporter, CsvExporter>(); ... resolve IEnumerable<IExporter>
```

One switch in one place is fine - it IS the extension point. Extract only on the second occurrence. Do not pre-build plugin architectures for cases that never had a second implementation.

## Liskov Substitution

C#-specific violations to reject:
- Overrides throwing `NotSupportedException` or `NotImplementedException`: the type does not honor the contract; split the interface or fix the hierarchy. (`ReadOnlyCollection.Add` is the cautionary tale, not a license.)
- Override that strengthens preconditions: base accepts null/empty, derived throws. Callers coded against the base break.
- `if (x is SpecificDerived d)` in code that receives the base type - the hierarchy has failed and callers are re-dispatching manually. Push the varying behavior into the type.
- Async contract narrowing: base method is truly async, override returns `Task.FromResult` after blocking work, or vice versa - behavioral surprise under load counts as a substitution failure.

## Interface Segregation

- An interface with 10+ members where implementations throw or no-op half of them: split by consumer. The consumer defines the interface shape, not the implementer.
- Test doubles are the detector: if every test mocks the same 2 of 12 methods, those 2 are the real interface.
- One-interface-per-class-by-reflex (`IUserService` with exactly one implementation, extracted only for mocking) is not ISP - it is acceptable ceremony at the application boundary, noise everywhere else. Do not demand interfaces for classes with no second implementation and no test seam need.

## Dependency Inversion

- High-level policy referencing concrete infrastructure: an `OrderService` constructing `SmtpClient` or `HttpClient` inline. Depend on `IEmailSender` defined in the application layer, implemented in infrastructure.
- The interface lives with the CONSUMER (application layer), not next to its implementation in the infrastructure project - otherwise the dependency arrow still points the wrong way.
- `new` on anything with I/O, time, randomness, or configuration inside business logic: inject it (`TimeProvider` instead of `DateTime.UtcNow` where testability matters).
- DIP does not mean "interface everything": `List<T>`, DTOs, pure functions, and framework types need no abstraction. Abstract at volatility boundaries: I/O, third-party services, things you will swap or fake.

## Review verdict guidance

Flag a SOLID issue only with the concrete cost attached: "this switch is duplicated in X and Y, next format touches both" - not "violates OCP". If you cannot name the cost, it is not a finding.
