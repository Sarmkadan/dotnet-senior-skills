---
name: input-validation-and-injection
description: Enforce input validation and prevent injection at API boundaries - SQL injection, over-posting, unbounded queries, and unvalidated input. Use when reviewing controllers, endpoints, and data-access code.
---

# Input Validation and Injection at API Boundaries

## Never trust input: validate at the boundary

Every piece of data entering the application must be validated at the API boundary before any processing. Validation is not optional; it is a security control. Place validation as close to the entry point as possible - controllers, minimal APIs, gRPC services, message consumers.

Reject in controllers/endpoints:
- Accepting entities directly as request bodies (mass assignment vulnerability)
- Using unvalidated route parameters, query strings, or headers in database queries
- Passing raw user input to raw SQL or dynamic LINQ
- Returning unbounded result sets to clients
- Allowing unbounded page sizes or offsets

```csharp
// non-compiling: illustrative
// WRONG: binding directly to entity enables mass assignment
[HttpPost]  
public async Task<IActionResult> Create(User user)  // user.Id, user.IsAdmin, user.CreatedAt are all settable!
{
    _db.Users.Add(user);
    await _db.SaveChangesAsync();
    return Ok(user);
}

// RIGHT: bind to request DTO with explicit validation
[HttpPost]
public async Task<ActionResult<UserDto>> Create(CreateUserRequest request, [FromServices] IValidator<CreateUserRequest> validator, CancellationToken ct)
{
    await validator.ValidateAndThrowAsync(request, ct);
    var user = request.ToEntity(); // explicit mapping, server-owned fields set here
    _db.Users.Add(user);
    await _db.SaveChangesAsync(ct);
    return CreatedAtAction(nameof(Get), new { id = user.Id }, user.ToDto());
}
```

## SQL injection: parameterize everything

EF Core LINQ queries are automatically parameterized and safe. The danger zone is raw SQL. Never concatenate user input into SQL strings.

Reject:
- `FromSqlRaw`/`ExecuteSqlRaw` with string interpolation or concatenation
- `FromSql`/`ExecuteSql` with `string.Format` or manual parameter building
- Dynamic SQL where identifiers come from user input

Accept:
- `FromSqlInterpolated` (converts interpolation to parameters)
- `FromSql` with parameter placeholders (`FromSql("SELECT * FROM Users WHERE Name = {0}", name)`)
- `FromSqlRaw`/`ExecuteSqlRaw` with anonymous object parameters

```csharp
// non-compiling: illustrative
// WRONG: string interpolation creates SQL injection
var users = db.Users.FromSqlRaw($"SELECT * FROM Users WHERE Name = '{name}'");

// WRONG: string.Format is just as dangerous
var users = db.Users.FromSqlRaw(string.Format("SELECT * FROM Users WHERE Name = '{0}'", name));

// WRONG: raw with concatenation
var users = db.Users.FromSqlRaw("SELECT * FROM Users WHERE Name = '" + name + "'");

// RIGHT: FromSqlInterpolated turns holes into parameters
var users = db.Users.FromSqlInterpolated($"SELECT * FROM Users WHERE Name = {name}");

// RIGHT: parameter object
var users = db.Users.FromSqlRaw("SELECT * FROM Users WHERE Name = {0}", name);

// RIGHT: anonymous object for multiple parameters
var users = db.Users.FromSqlRaw("SELECT * FROM Users WHERE Name = {0} AND Age > {1}", name, minAge);
```

Identifiers (table names, column names, ORDER BY direction) cannot be parameterized. Always allowlist them against a fixed set:

```csharp
private static readonly HashSet<string> AllowedSortColumns = new(StringComparer.OrdinalIgnoreCase)
{
    "Name", "Email", "CreatedAt", "Id"
};

[HttpGet]
public async Task<IActionResult> List([FromQuery] string sortBy = "Name")
{
    if (!AllowedSortColumns.Contains(sortBy))
        return BadRequest("Invalid sort column");
    
    var query = sortBy switch
    {
        "Name" => db.Users.OrderBy(u => u.Name),
        "Email" => db.Users.OrderBy(u => u.Email),
        _ => db.Users.OrderBy(u => u.Name)
    };
    return Ok(await query.ToListAsync());
}
```

## Pagination: always bound and capped

Never allow clients to request unbounded result sets. Every paginated endpoint must:
- Accept `pageSize` and `pageNumber` or `skip`/`take` parameters
- Validate these parameters with `[Range]` or equivalent
- Apply an absolute maximum page size (typically 100-500 items)
- Return a `PagedResult<T>` or similar wrapper with total count

Reject:
- Endpoints without pagination parameters that could return thousands of rows
- Parameters without validation
- Page sizes above the maximum (e.g., `?pageSize=1000000`)

```csharp
// non-compiling: illustrative
// WRONG: unbounded query
[HttpGet("users")]
public async Task<IActionResult> GetAllUsers()
{
    var users = await _db.Users.ToListAsync(); // N+1, memory explosion
    return Ok(users);
}

// WRONG: pagination without validation
[HttpGet("users")]
public async Task<IActionResult> GetUsers([FromQuery] int pageNumber = 1, [FromQuery] int pageSize = 10)
{
    var users = await _db.Users
        .OrderBy(u => u.Name)
        .Skip((pageNumber - 1) * pageSize)
        .Take(pageSize)
        .ToListAsync();
    return Ok(users);
}

// RIGHT: validated pagination with maximum
public record GetUsersRequest([property: Range(1, int.MaxValue)] int PageNumber = 1,
                           [property: Range(1, 500)] int PageSize = 50);

[HttpGet("users")]
public async Task<ActionResult<PagedResult<UserDto>>> GetUsers([FromQuery] GetUsersRequest request, CancellationToken ct)
{
    var query = _db.Users.OrderBy(u => u.Name);
    var total = await query.CountAsync(ct);
    var users = await query
        .Skip((request.PageNumber - 1) * request.PageSize)
        .Take(request.PageSize)
        .ProjectToDto()
        .ToListAsync(ct);
    
    return Ok(new PagedResult<UserDto>(users, total));
}
```

## Mass assignment: never bind entities directly

Binding a request body to an entity allows clients to set any property, including server-owned fields like `Id`, `CreatedAt`, `IsAdmin`, `Status`, or foreign keys. Always use request DTOs with explicit mapping.

Reject:
- `[FromBody] Entity` in controller parameters
- AutoMapper profiles that map request DTOs to entities with `ForAllMembers` or similar broad mappings
- Copying properties from request to entity without field-by-field validation

Accept:
- Request DTOs with only client-settable fields
- Explicit mapping methods (`ToEntity`, `ToCommand`, `ToDto`)
- Constructor initialization of server-owned fields

```csharp
// non-compiling: illustrative
// WRONG: mass assignment vulnerability
[HttpPost]
public async Task<IActionResult> UpdateUser([FromBody] User user)
{
    var existing = await _db.Users.FindAsync(user.Id);
    if (existing == null) return NotFound();
    
    // DANGER: client can set IsAdmin, CreatedAt, etc.
    _mapper.Map(user, existing);
    await _db.SaveChangesAsync();
    return NoContent();
}

// RIGHT: request DTO with explicit mapping
public record UpdateUserRequest(string Name, string Email, string? Phone);

[HttpPut("users/{id}")]
public async Task<IActionResult> UpdateUser(int id, [FromBody] UpdateUserRequest request, CancellationToken ct)
{
    var user = await _db.Users.FindAsync(new object?[] { id }, ct);
    if (user == null) return NotFound();
    
    // Explicit mapping - only client-settable fields
    user.Name = request.Name;
    user.Email = request.Email;
    user.Phone = request.Phone;
    
    await _db.SaveChangesAsync(ct);
    return NoContent();
}

// Alternative: constructor initialization for new entities
public record CreateUserRequest(string Name, string Email, string Password);

[HttpPost("users")]
public async Task<ActionResult<UserDto>> CreateUser([FromBody] CreateUserRequest request, CancellationToken ct)
{
    // Server owns these fields
    var user = new User
    {
        Id = Ulid.NewUlid(),
        Name = request.Name,
        Email = request.Email,
        PasswordHash = _passwordHasher.HashPassword(request.Password),
        CreatedAt = DateTime.UtcNow,
        IsActive = true,
        Role = UserRole.User
    };
    
    _db.Users.Add(user);
    await _db.SaveChangesAsync(ct);
    return CreatedAtAction(nameof(GetUser), new { id = user.Id }, user.ToDto());
}
```

## Query parameters: validate and sanitize

Route values, query strings, and headers can be manipulated by clients. Validate them before use:

- Route parameters (e.g., `{id}`) should be validated for format and existence
- Query strings should have bounded ranges and allowlisted values
- Headers should match expected patterns

```csharp
// non-compiling: illustrative
// WRONG: no validation on route parameter
[HttpGet("users/{id}")]
public async Task<IActionResult> GetUser(int id) // accepts negative, zero, very large numbers
{
    var user = await _db.Users.FindAsync(id);
    return user == null ? NotFound() : Ok(user.ToDto());
}

// RIGHT: validate route parameter
[HttpGet("users/{id}")]
public async Task<IActionResult> GetUser([FromRoute] int id)
{
    if (id <= 0)
        return BadRequest("Invalid user ID");
    
    var user = await _db.Users.FindAsync(id);
    return user == null ? NotFound() : Ok(user.ToDto());
}

// For GUID/ULID identifiers, use proper validation
[HttpGet("users/{id}")]
public async Task<IActionResult> GetUser([FromRoute] string id)
{
    if (!Ulid.TryParse(id, out _) && !Guid.TryParse(id, out _))
        return BadRequest("Invalid ID format");
    
    var user = await _db.Users.FindAsync(id);
    return user == null ? NotFound() : Ok(user.ToDto());
}
```

## File uploads: validate everything

File uploads are user input. Validate:
- File extension against an allowlist
- Content type against an allowlist
- File size against a maximum
- File content (magic numbers) to prevent polyglot files
- Never trust the original filename for storage

```csharp
// non-compiling: illustrative
private static readonly HashSet<string> AllowedExtensions = new(StringComparer.OrdinalIgnoreCase)
{
    ".jpg", ".jpeg", ".png", ".gif", ".pdf"
};

private static readonly HashSet<string> AllowedContentTypes = new(StringComparer.OrdinalIgnoreCase)
{
    "image/jpeg", "image/png", "image/gif", "application/pdf"
};

[HttpPost("upload")]
public async Task<IActionResult> UploadFile(IFormFile file, CancellationToken ct)
{
    if (file == null || file.Length == 0)
        return BadRequest("No file provided");
    
    if (file.Length > 10_000_000) // 10MB
        return BadRequest("File too large");
    
    var extension = Path.GetExtension(file.FileName);
    if (string.IsNullOrEmpty(extension) || !AllowedExtensions.Contains(extension))
        return BadRequest("Invalid file type");
    
    var contentType = file.ContentType;
    if (string.IsNullOrEmpty(contentType) || !AllowedContentTypes.Contains(contentType))
        return BadRequest("Invalid content type");
    
    // Validate magic numbers
    using var ms = new MemoryStream();
    await file.CopyToAsync(ms, ct);
    if (!IsValidFileFormat(ms.ToArray(), extension))
        return BadRequest("Invalid file content");
    
    // Store with server-generated name
    var fileName = $"{Guid.NewGuid()}{extension}";
    var path = Path.Combine("uploads", fileName);
    await using (var fs = new FileStream(path, FileMode.Create))
    {
        ms.Position = 0;
        await ms.CopyToAsync(fs, ct);
    }
    
    return Ok(new { fileName });
}
```

## Command injection: sanitize file paths and command arguments

Never pass unvalidated user input to:
- File operations (`File.Open`, `Directory.CreateDirectory`)
- Process execution (`Process.Start`, `IHostedService` commands)
- Dynamic library loading
- Environment variables from user input

```csharp
// WRONG: path traversal
[HttpGet("download")]
public IActionResult DownloadFile([FromQuery] string fileName)
{
    var path = Path.Combine("user-files", fileName); // ../etc/passwd possible
    return PhysicalFile(path, "application/octet-stream");
}

// RIGHT: allowlist and sanitize
[HttpGet("download")]
public IActionResult DownloadFile([FromQuery] string fileName)
{
    var allowedFiles = new HashSet<string> { "report.pdf", "data.csv", "image.jpg" };
    if (!allowedFiles.Contains(fileName))
        return BadRequest("Invalid file");
    
    var path = Path.Combine("user-files", fileName);
    if (!System.IO.File.Exists(path))
        return NotFound();
    
    return PhysicalFile(path, "application/octet-stream");
}
```

## Validation tools and patterns

Use the right tool for the job:

- **FluentValidation**: Rich validation rules, async validators, complex scenarios
  ```csharp
  public class CreateUserRequestValidator : AbstractValidator<CreateUserRequest>
  {
      public CreateUserRequestValidator()
      {
          RuleFor(x => x.Email).EmailAddress();
          RuleFor(x => x.Password).MinimumLength(8);
          RuleFor(x => x.Name).NotEmpty().MaximumLength(100);
      }
  }
  ```

- **DataAnnotations**: Simple validation, works with model binding
  ```csharp
  public record CreateUserRequest(
      [Required, EmailAddress] string Email,
      [Required, MinLength(8)] string Password,
      [Required, MaxLength(100)] string Name
  );
  ```

- **Manual validation**: When you need custom logic or early rejection
  ```csharp
  [HttpPost]
  public async Task<IActionResult> Create([FromBody] CreateUserRequest request, CancellationToken ct)
  {
      if (await _userService.EmailExistsAsync(request.Email, ct))
          return Conflict("Email already in use");
      
      if (!request.Password.IsStrongPassword())
          return BadRequest("Password not strong enough");
      
      // ...
  }
  ```

## Summary: the validation checklist

When reviewing API boundary code, ask:

1. **Are entities returned or accepted at the boundary?** → Reject (mass assignment)
2. **Is raw SQL used with string concatenation or interpolation?** → Reject (SQL injection)
3. **Are pagination parameters unbounded or unvalidated?** → Reject (memory/DoS risk)
4. **Are route/query/header parameters validated?** → If not, reject
5. **Are file uploads validated for type, size, and content?** → If not, reject
6. **Is user input used in file paths, commands, or dynamic SQL identifiers?** → If yes without allowlist, reject

The rule: **Validate everything, trust nothing.**
