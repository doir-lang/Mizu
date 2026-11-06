# Agent guidelines for Mizu

## Comments

- Keep comments minimal.
  Write one only where the code does something difficult to follow on its own: a non-obvious invariant, a subtle memory or lifetime rule, a workaround for a compiler bug, or why an apparently simpler approach would be wrong.
  Do not restate what the code already says.
- Cap every free-standing comment (a `//` or `/* */` block that is not a documentation comment) at 25 words.
  If it needs more, the code or its documentation should carry the explanation instead.
- Editors here soft-wrap, so write each comment, and each paragraph of a DDoc comment, on a single line rather than hard-wrapping it at a column.
- Do not leave commented-out code, change logs, or notes about what was changed in a comment; those belong in commit messages.

## Documentation

- Put a DDoc comment (`///` or `/** */`) directly above every publicly accessible definition: each public or package-visible function, struct, enum, alias, template, mixin template, and module-level variable.
  Private helpers do not need one.
- Every DDoc comment on a function or template includes an example of its use in an `Examples:` section, as a `---` code block:

  ```d
  /// Configures a new Mizu environment to run `program`, zeroing register `x0`.
  ///
  /// Examples:
  /// ---
  /// static immutable Opcode[1] program = [Opcode(&halt)];
  /// RegistersAndStack env;
  /// setupEnvironment(env, program[]);
  /// assert(env.programStart == program.ptr);
  /// ---
  void setupEnvironment(ref RegistersAndStack env, const(Opcode)[] program) { ... }
  ```

- Keep examples short, and make them correct against the current API: they should compile and pass as written under `-betterC`.
  Check them with `python3 tools/doctest.py`, which compiles and runs every example and reports public definitions missing documentation or an example.
  Examples see `import mizu;` and their own module unqualified, as user code would; anything else needs its full name.
  Module documentation may sketch configuration or user code in a `---` block; doctest does not compile those.
- Every instruction (a function with the `mizu.opcode.Instruction` signature) documents, under `Params:`, each of `out_`, `a`, and `b` it uses and what it does with it: whether it is a register index or an immediate, and whether it is read or written.
  Write `immediate` when `a` and `b` together hold one 32-bit value set with `setImmediate`, and say when `b` is a signed offset set with `setBranchImmediate`.
  Also document any effect on the stack pointer, program counter, or environment beyond those fields.
  Its example is a short program run with `startFromEnvironment` that asserts on the registers or stack it leaves:

  ```d
  /**
  * Adds two numbers.
  *
  * Params:
  *   out_ = register to store `a + b` in
  *   a = register holding the first value
  *   b = register holding the second value
  *
  * Examples:
  * ---
  * static immutable Opcode[4] program = [
  * 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(40),
  * 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
  * 	Opcode(&add, Registers.t(2), Registers.t(0), Registers.t(1)),
  * 	Opcode(&halt),
  * ];
  * RegistersAndStack env;
  * setupEnvironment(env, program[]);
  * cast(void) startFromEnvironment(program[], env);
  * assert(env.memory[Registers.t(2)] == 42);
  * ---
  */
  void* add(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) { ... }
  ```

- When a platform `static if` or `version` gives an API several implementations, document the first branch's definitions; an `else` branch reimplementing the same API needs no second copy.
- Document Python too: a docstring on each module, and on each function and class whose name does not start with `_`.
  A Python tool's module docstring says how to run it, as a usage line (`python3 tools/doctest.py`).
- A DDoc comment is documentation, not a free-standing comment, so the 25-word cap does not apply to it, but keep it as brief as the definition allows.

## Style

- Prefer plain-data structs operated on by free functions that take them by `ref` (for example `setupEnvironment(env)`, `fillStackBottom(env, binary)`), rather than methods.
  Use member functions only for operator overloads, for `@property` accessors that name part of a field, and for what a language protocol requires to be a member, such as range primitives (`empty`, `front`, `popFront`) or an `alias this` target.
  Python is not ported, so it uses classes and methods where they are idiomatic.
- Prefer fully qualified names to aliasing imports: call `fp.dynarray.free(a)` rather than `import fp.dynarray : dynFree = free;` or `alias dynFree = fp.dynarray.free;`.
  A `static import` keeps a module's names out of scope so every use has to be qualified.
- One mizu module uses another, or a bc-threads or libfp module, through a `static import`, so every call names its layer (`mizu.opcode.setupEnvironment`, `bc.semaphore.post`, `fp.dynarray.pushBack`).
  The exception is a `public import` that re-exports names as part of the module's own API.
- In Python, import the module and call qualified (`fp.dynarray.pushBack`, `pathlib.Path`) rather than aliasing or importing names directly; the exception is `from __future__ import …`.
- Name D in camelCase, and Python in snake_case, with Python classes in PascalCase.
  Add a trailing underscore only when the plain name is a keyword of its language (`out_`, `in_`, `with_`, `null_`, `string_`).
- Make names document themselves, so neither a comment nor a wrapper is needed to explain them:
  - Spell words out: no C-heritage names or abbreviations (`allocate`, not `malloc`; `context`, not `ctx`; `array`, not `da`).
  - Name the effect or the result, not the mechanism (`lockForReading`, not `readLock`; `wordEnd` for a function returning where a word ends).
  - Do not repeat what the qualified module path or the types already say: calls are always qualified, so `fp.pointer.allocate` needs no `Memory`.
  - Name a sentinel for what it means where it is used, and split a sentinel that would mean two things (`notInterned` and `refused`, not one `none`).
  - Purpose suffixes read `ForReading`/`ForWriting` (`lockForWriting`, `getForWriting`, `mapForWriting`).
  - Keep the words every reader already knows: `free`, `length`, `find`, `insert`, `hash`, `create`, `contains`, `pushBack`, `pushFront`, `removeAt`.
- Avoid one-line wrappers: a function whose body only forwards to another call, fixing an argument or two or reaching into a field, adds a name to learn and hides the call it stands for.
  Write the call out at each use, even when it is long.
  Before keeping a wrapper, see whether renaming what it wraps would make the direct call read as well.
  A wrapper a protocol requires (a hook found by name, an accessor of a private field) is marked `// wrapper: <reason>` on the line above its documentation comment.
- Indent with tabs.
- Under a `@nogc nothrow:` label, do not repeat those attributes on the declarations the label covers: every declaration at that scope, including those inside `version` and `static if` blocks.
  Function attributes do not propagate into aggregate declarations, so members of a non-template struct, class or union, and hooks of a non-template struct declared inside a function or `unittest`, must state `@nogc nothrow` themselves, or calls from `@nogc` code fail to compile.
  Members of a template struct need no repetition because their attributes are inferred.

## Failure and invariants

- Every function that can fail says in its DDoc how it reports failure (null, `false`, an empty `Nullable`, `fp.pointer.notFound`, `fp.pointer.allocationRefused`), and what state it leaves its arguments in; prefer leaving them as they were.
- Do not return a `bool` with the result in an `out` parameter (`bool find(…, out T x)`): return `std.typecons.Nullable!T`, null on failure, so the result cannot be read without the check.
  Several results go in a struct the `Nullable` holds.
- Never drop the result of a call that can fail: check it, or discard it explicitly when failure is impossible or harmless there, with `cast(void)` in D and `_ = …` in Python.
  Tests assert on it.
- When a limit on one value follows from another (such as a bit position), name the constant once, derive the others from it, and `assert` the limit where the value is accepted.
- Put test-only code, such as helper functions and globals the tests use, inside `version(unittest)` in D, and in the test files rather than the modules they test in Python.
- `tests/runner.d` runs only the modules it lists, so add a new module with unittests to its `modules` list.
- Keep test coverage as close to 100% as possible: add a test for every new branch and failure path, and check with `python3 tools/coverage.py`; an uncovered line needs a reason, such as being unreachable or platform-specific.
- Threading is a compile-time choice (`MizuNoHardwareThreads`), so run the tests under both the `unittest` and `unittest-coroutine` configurations.

## Organization

- Where possible, group related definitions into sections (for example: types and layout, queries, creation and freeing, growth, removal), separated by blank lines, and order them so a reader meets a type before the functions built on it.
- Whenever possible, define a function before anything that uses it, so a module reads bottom-up from its building blocks; a Python tool ends with `main`.
  When functions use each other in a cycle, define first the one that more of the module uses.
- Keep a module's tests in the same order as the code they test.
- Prefer merging a new test case into an existing test (a D `unittest` block, a Python test function) covering the same section over adding a new one; add one only when no existing test fits.

## Markdown

- Put each sentence of a Markdown file on its own line, a list item's or block quote's later sentences continuing under its marker, so a diff shows the sentences an edit changed.
  Never hard-wrap a sentence; editors here soft-wrap.

## Layering

libfp is the bottom of a stack: bc-threads builds on it; libdiagnose, libECRS, Mizu and bc-fetch on those; DOIR on all of them.
Every library in the stack forwards these rules.

- Put code in the lowest library that has everything it needs.
  A library above may hold only what is specific to it: threads in bc-threads, entities in libECRS, diagnostics in libdiagnose, networking in bc-fetch, the language in DOIR.
  Before writing a helper, search the libraries below for it; if it is missing, add it there, with a test, rather than locally.
- Only libfp, bc-threads, bc-fetch and Mizu's FFI layer (`mizu.ffi`, which loads and calls into native libraries) import `core.sys.*` or `core.stdc.*`, or call OS APIs; everything else reaches the OS and the C runtime through them (`fp.pointer.copy` and `fill`, `fp.string.sliceTerminated`, `fp.io.print` and `abort`).
- View a plain field atomically through `bc.platform.asShared`, never a hand-written `cast(shared …)`.
- Hold owned memory in a struct through `fp.lifecycle.Owned` rather than hand-written `finalize` and `copyTo` hooks.
- Compare and hash a value through `fp.lifecycle.equal` and `fp.lifecycle.contentHash`, which use its hooks if it declares them.
  Never `memcmp` or hash a struct's raw bytes: its padding is in them.
- Check these rules with `python3 tools/lint.py`, which every library keeps a copy of, each with its own `CONFIG` and the same `PUSHED` registry.
  When code moves into a lower library, add the pattern it replaced to `PUSHED` in every copy, with the replacement as its hint, so the old way cannot come back.

## Bugs

- If you find a bug while working, fix it, with a test that would have caught it, rather than only reporting it.
  Only when the fix would likely take a long time, report it instead, saying what you found and where.
