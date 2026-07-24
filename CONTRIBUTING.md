# Contributing to the DotNet Senior Skills Repository

Thank you for considering contributing to the DotNet Senior Skills repository! We appreciate your help in making this repository a valuable resource for the community.

## Quality Bar

Before submitting a pull request, please ensure that your contribution meets the following quality bar:

* Implement the feature completely and for real. If some part cannot be implemented for real, omit it - never fake a result, never hardcode a return value, never write "simplified for demo" / "in a real application".
* Guard clauses first: `ArgumentNullException.ThrowIfNull(x)` / `ArgumentException.ThrowIfNullOrEmpty(s)` at the top of each public method.
* Modern C#: expression-bodied members where they fit, pattern matching over if-chains, target-typed new.
* XML doc comments on every new public member, including `<exception>` tags for every throw.

## Hard Rules

The following hard rules must be followed to ensure that your contribution is accepted:

* Do NOT touch `.csproj`, `.sln`, `.slnx`, or `Directory.Build.props` files, or any other existing file except what's needed for this task.
* Do NOT write tests unless explicitly asked. Do NOT add NuGet packages unless explicitly needed and already-available in the BCL is not enough.
* No mention of AI/assistant in code or commits.
* The whole solution MUST still compile with `dotnet build`.
* Commit message: conventional commits style, lowercase, no AI mentions.

## Example Skill Skeleton

Here is an example of a fully worked skill skeleton:

