# Zit Style Guide

This style guide establishes the coding standards for **Zit**, focusing on safety, performance, and developer experience.

---

## 1. Safety

Safety is our highest priority. We enforce strict guidelines to ensure correctness and prevent runtime failures.

### Assertions & Correctness
- **Assert Pre/Postconditions & Invariants:** Every function must check its inputs and state.
- **Assertion Density:** Maintain an average of at least **two assertions per function**.
- **Fail-Fast:** Assertion failures represent programmer errors; the program must crash rather than proceed with corrupt state.
- **Split Compound Assertions:** Prefer `assert(a); assert(b);` over `assert(a and b);` for clearer error tracing.
- **Pair Assertions:** Enforce invariants in two different paths (e.g., check data validity both before writing to disk and after reading from disk).
- **Implications:** Use single-line `if` statements for implications: `if (a) assert(b);`.
- **Positive & Negative Space:** Assert both the properties you expect *and* what you do not expect.

### Control Flow & Bounding
- **No Recursion:** All control flow must have a compile-time or runtime bound.
- **Limit Everything:** Every loop must have a fixed upper bound (e.g., walk limits) to prevent infinite loops.
- **Simple Control Flow:** Keep nesting shallow. Split complex `else if` chains into explicit `else { if { ... } }` blocks.
- **Function Line Limit:** Hard limit of **70 lines per function**.
- **Centralize Control Flow:** "Push `if`s up and `for`s down". Keep decision branching in parent functions, and execute pure/leaf loops in helpers.

### Types & Memory
- **Explicitly-Sized Types:** Use `u32`, `u64`, etc., for index, length, and size variables. Avoid architecture-specific `usize` unless interacting directly with Zig array/slice interfaces.
- **Scope Minimization:** Declare variables at the smallest possible scope, close to their point of use.
### Error Handling
- **All errors must be handled:** Swallowed or unhandled errors are the primary source of catastrophic system failures.
- **Explicit Error Set Reference:** All custom error returns and matches must explicitly reference their error set (e.g., `ZitError.BadUsage` or `ZitError.InvalidOID`) rather than the anonymous `error.Name` syntax. Standard library errors must reference their fully qualified module error sets (e.g., `std.Io.Dir.OpenError.FileNotFound`).

---

## 2. Performance

Performance must be designed in, not refactored later.
- **Design upfront:** Optimize before writing code, as the largest wins are architectural.
- **Back-of-the-Envelope Sketches:** Compute resource requirements (network, disk, memory, CPU) and constraints before implementing.
- **Batching:** Amortize resource access costs (I/O, context switching) by batching operations.
- **Sprinter CPU:** Keep code paths predictable. Help the compiler optimize by keeping hot loops in standalone functions with primitive arguments.

---

## 3. Developer Experience & Naming

Clear code is readable, self-documenting code.

### Naming Conventions
- **Case Conventions:** Use `snake_case` for variables, functions, and file names (e.g., `git_dir.zig`, `space_pos`).
- **No Abbreviations:** Use descriptive, full names (e.g., `allocator` instead of `alloc`, `target` instead of `dst`).
- **Acronyms:** Use full capitalization for acronyms (e.g., `OID` instead of `Oid`, `SHA` instead of `Sha`).
- **Qualifiers & Units:** Put units and qualifiers at the end of variables (e.g., `latency_ms_max` instead of `max_latency_ms`).
- **Symmetric Names:** Match names in pairs for alignment (e.g., `source` and `target` align better than `src` and `dest`).

### Struct Organization
- **Declaration Order:** Structs must be organized in the following order:
  1. Fields
  2. Nested Types
  3. Methods
- **In-place Initialization:** For large structs, pass an out pointer (e.g., `fn init(self: *T)`) to ensure pointer stability and eliminate copy-move overhead.

### Documentation & Comments
- **Comments as Prose:** Comments must be complete sentences (start with a capital letter, end with a period, space after `//`).
- **Explain "Why":** Comments should explain the *rationale* behind code design, not reiterate what the code does.

---

## 4. Code Style & Formatting

- **Indentation:** Use **4 spaces** for indentation.
- **Column Limit:** Hard limit of **100 columns** per line. Wrap lines cleanly.
- **One-liners:** Prefer one-liner code blocks for simple conditions or error handling (e.g., `if (cond) return err;` or `expr catch return err;`) on a single line instead of splitting them across multiple lines, provided it fits within the 100-column limit.
- **Format Tooling:** Run `zig fmt` on all source files before committing.

---

## 5. Dependencies & Tooling

- **Zero Dependencies:** Apart from the Zig toolchain, the project has a strict zero external dependencies policy.
- **Zig for Scripts:** Write utility scripts in Zig (e.g., `scripts/*.zig`) instead of shell/bash to ensure cross-platform portability and type safety.

---

*Adapted from the TigerBeetle style guide: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md*