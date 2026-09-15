![Mizu's Mascot](docs/mizu.svg)

# Mizu

[![Unlicensed](https://flat.badgen.net/github/license/joshuadahlunr/mizuvm)](LICENSE) [![DOI](https://flat.badgen.net/static/DOI/10.5281%2Fzenodo.15578022/cyan)](https://doi.org/10.5281/zenodo.15578021)

Mizu is a lightweight, easily extensible interpreter loosely modeled after RISC-V assembly.

Programs are an array of opcodes that manipulate virtual registers and a virtual stack. This is
the D `-betterC` implementation, ported from the original C++ one; see
[Notes on the port](#notes-on-the-port) for where the two differ.

Take a read through the [documentorial](docs/index.md) (documentation and tutorial rolled into
one) to learn about the details of Mizu programs and our instructions.

The simplest "useful" Mizu program is:

```d
import mizu;

static immutable Opcode[3] program = [
    Opcode(&loadImmediate, Registers.t(0)).setImmediate(40),
    Opcode(&debugPrint, 0, Registers.t(0)),
    Opcode(&halt),
];

extern(C) int main() {
    RegistersAndStack environment;
    setupEnvironment(environment, program[]);

    startFromEnvironment(program[], environment);
    return 0;
}
```

## Features

* Small — the `fib` example is a 29kB executable (26kB stripped)
* No runtime: `-betterC` throughout, `@nogc nothrow`, no GC, no druntime, no static constructors
* Fast: recursive Fibonacci through a tail-call-threaded dispatch loop
* Simple and easily extensible instructions
* Integer and float (`f32`/`f64`) support
* Threading instructions backed by [bc-threads](https://github.com/doir-lang/bc-threads),
  with go-like channels for inter-thread communication
* A fallback coroutine scheduler for single-core machines
* Built-in FFI: Mizu calls external functions the same way it calls its own — substitute
  `ffi.call` for `jumpTo`
* A portable binary format, and a D source-code generator for snapshots

## Requirements

* **LDC.** This is not a preference. See [Tail calls](#tail-calls) below.
* **An optimizing build** (`-O1` or higher). Also not a preference.
* **libffi**, unless you build with `-version=MizuNoFFI`. Any reasonably recent version works;
  Mizu declares the handful of entry points it needs itself.

## How to integrate

Add Mizu to your `dub.json` and make sure your own package is `-betterC` and optimized:

```json
{
    "dependencies": {
        "mizu": {
            "repository": "git+https://github.com/joshuadahlunr/MizuVM.git",
            "version": "<commit hash>"
        }
    },
    "dflags-ldc": ["-betterC", "-checkaction=C"],
    "buildTypes": {
        "debug": { "buildOptions": ["debugMode", "debugInfo", "optimize"] }
    }
}
```

`dub` has a long-standing bug resolving git dependencies by branch name
([dub#2697](https://github.com/dlang/dub/issues/2697),
[dub#3047](https://github.com/dlang/dub/issues/3047)), so pin a commit hash rather than a
branch, the way [bc-threads](https://github.com/doir-lang/bc-threads) pins libfp.

Then `import mizu;` for the VM and every instruction, plus `import mizu.ffi;` if you want the
foreign function interface.

## Building this repository

```sh
dub build --config=library --compiler=ldc2    # the static library
dub test --compiler=ldc2                     # unit tests + end-to-end VM tests
dub run -c example-fib --compiler=ldc2        # recursive Fibonacci
dub run -c example-bubble --compiler=ldc2     # bubble sort on Mizu's stack
dub run -c example-threads --compiler=ldc2    # forked thread + channel + FFI call
dub run -c example-triangle --compiler=ldc2   # a GLFW/OpenGL triangle, entirely over the FFI
```

`--compiler=ldc2` is not a suggestion. DMD does not link the test suite at all — it emits calls to
druntime helpers (`_memset128ii`, `core.bitop.byteswap`) that `-betterC` then refuses to link
against — and even if it did, it performs no tail call optimization, so the dispatch described
under [Tail calls](#tail-calls) would overflow the stack on the first loop of any size.

To run the same suite against the coroutine scheduler instead of OS threads, build and run that
configuration directly:

```sh
dub build -c unittest-coroutine --build=unittest --compiler=ldc2
./bin/mizu-tests-coroutine
```

`dub test -c unittest-coroutine` runs the tests too, but for a non-default configuration dub
substitutes its own druntime-based `main`, so [tests/runner.d](tests/runner.d) never runs and you
get druntime's bare "all unit tests have been run successfully" instead of the per-module progress
and the test count. Build and run the binary yourself, as above, to see how much actually ran.
`dub test` with no `-c` picks up the `unittest` configuration and the runner correctly.

### Coverage

```sh
tools/coverage.sh        # per-module summary
tools/coverage.sh -v     # ... and every uncovered line
```

`-cov` records its line counts through druntime, which `-betterC` does not have, so the script
builds the same sources and the same tests as ordinary D — `tests/runner.d` supplies a druntime
`main` when `MizuCoverage` is set. It measures with `-cov=ctfe`, because the instruction table in
[source/mizu/lookup.d](source/mizu/lookup.d) is built entirely during compilation.

Threading is a compile-time choice, so no single build contains both halves of
[source/mizu/instructions/parallel.d](source/mizu/instructions/parallel.d). The script builds and
runs **both** configurations and merges the counts, taking a line as covered if either build
reached it; measuring only the default build would report that file as fully covered while never
compiling the coroutine scheduler at all.

Four lines are uncovered. Two are defensive guards on contracts that other code owns:

- `mizu.ffi.loader.loadShared` checks that its path allocation succeeded. libfp returns null only
  for an empty path, which the function rejects a few lines earlier, and a real allocation
  failure never reaches the check either — libfp writes through the failed allocation before
  returning it. The check is kept for if and when that contract is honoured.
- `mizu.ffi.instructions.createInterface` checks `ffi_prep_cif`'s status. `FFI_BAD_TYPEDEF` is
  out of reach, since the `pushType*` instructions can only push libffi's own type descriptors,
  but `FFI_BAD_ABI` is not: the ABI constant is hand-transcribed per target in
  [source/mizu/ffi/libffi.d](source/mizu/ffi/libffi.d), and this is what catches a wrong value on
  a target this suite does not run on.

The other two are `mutexWriteLock` and `mutexReadLock` yielding on a mutex somebody else holds,
and no terminating program can reach them. With the coroutine fallback a mutex *is* the register
holding it (see `mizu.instructions.parallel.mutexCreate`), and forking hands the new context a
copy of the register file, so the two contexts end up with a lock each. A context that yields on
a locked mutex is therefore waiting for a release that can never arrive: reaching either line
means hanging on it. The try-lock instructions have no such problem — they report the refusal and
carry on — and they are covered.

## Tail calls

Mizu dispatches each instruction by tail-calling the next one, so a program of any length runs
in a single stack frame. If that tail call is not eliminated, every instruction leaks a frame
and a loop of any size overflows the stack.

The C++ original used clang's `__attribute__((musttail))`, which clang honours even at `-O0`.
**D has no equivalent.** There is no `musttail` pragma in LDC, and emitting a `musttail` call
through `pragma(LDC_inline_ir)` does not help: the IR function LDC generates has to be inlined
into the instruction, and LLVM's inliner strips `musttail` from an inlinee whose call site is
not itself `musttail`.

So the port relies on LLVM's ordinary tail call optimization, which means:

| Compiler | Optimization | Result |
| --- | --- | --- |
| LDC | `-O1` and above (`-g` is fine) | works |
| LDC | `-O0` | **stack overflow** |
| DMD | any | **stack overflow** — DMD does not tail-call at all |

`dub.json` therefore overrides the `debug` and `unittest` build types to add `optimize`, so
`dub build` and `dub test` cannot accidentally produce a broken VM, and `mizu.opcode` emits a
compile-time warning under DMD. If you build Mizu by hand, pass `-O2`.

This is a narrower window than the C++ version's, which is why it is called out here rather
than buried: the C++ README warned that MSVC and avr-gcc would produce programs that crash, and
the D port's equivalent warning is "not LDC, or not optimized".

## Configuration

Boolean knobs are D `version` identifiers, which `dub` can set for you:

```json
"versions": ["MizuNoHardwareThreads", "MizuEnableTracing"]
```

| Version | Effect |
| --- | --- |
| `MizuNoHardwareThreads` | Emulate threads with the round-robin coroutine scheduler. Implied on WASM. |
| `MizuEnableTracing` | Every instruction prints its name and operands as it runs. |
| `MizuNoFFI` | Drop the FFI entirely, and with it the libffi dependency. |
| `MizuNoLibFFI` | Keep the FFI instructions but bind no backend; the call instructions abort. |

D has no equivalent of `-DNAME=value`, so the two numeric knobs that used to be CMake cache
variables are `enum`s in [source/mizu/config.d](source/mizu/config.d):
`stackSizeKilobytes` (was `MIZU_STACK_SIZE`) and `maximumLabelSearch` (was
`MIZU_MAXIMUM_LABEL_SEARCH`).

## Notes on the port

Most of the translation is mechanical. These are the places where it is not, and why.

**Names.** Instructions and API functions are camelCase, following the convention
[libfp's own D port](https://github.com/doir-lang/libfp/tree/D) used when it turned
`fp_string_view_length` into `length`. So `load_immediate` is `loadImmediate`,
`setup_environment` is `setupEnvironment`, and so on.

**`out` is a D keyword**, so `Opcode`'s first register field is `out_`. `a` and `b` are
unchanged.

**The register namespace is `Registers`.** C++ could write `registers::a(0)` inside a function
whose parameter was also called `registers`; D cannot. `registers` remains as an alias for
parity with the C++ spelling, but instruction bodies say `Registers.a(0)`.

**`MIZU_NEXT()` is `mixin(mizuNext)`.** It has to stay a mixin rather than becoming a function,
because the dispatch must be a tail call made by the instruction itself.

**Immediates are packed with shifts, not a reinterpreting cast.** The C++ wrote a `uint32_t`
over the `a`/`b` register pair. D cannot constant-fold that, and a program full of immediates
is much nicer as read-only data than as something assembled at startup, so `setImmediate` writes
`a = low half, b = high half` explicitly. On a little-endian host the bytes are identical; the D
version is simply also correct on a big-endian one. Programs that embed *host pointers* still
have to be built at run time, since an address is not a compile-time value — see
[examples/bubble.d](examples/bubble.d).

**The instruction lookup table is built at compile time.** The C++ registered instructions
through `bool <name>_registered` static initializers into three `std::unordered_map`s;
`-betterC` has no static constructors. `mizu.lookup` instead enumerates the instruction modules
with `__traits(allMembers)` and emits a table into read-only data. Nothing allocates, nothing
runs before `main`, IDs no longer depend on static initialization order — and
`release_lookup_data()` is gone, because there is nothing left to release.

**Exceptions are gone.** `MIZU_THROW` becomes `mizu.exception.fatal`, which prints to `stderr`
and aborts. The dynamic loader, which used a `try`/`catch` to implement "try each of these
libraries", now returns null and records `mizu.ffi.loader.lastError`.

**`registers_and_stack::calculate_program_end` returned `pc - MIZU_MAXIMUM_LABEL_SEARCH`**, the
same expression as `calculate_program_start`, which made a `findLabel` in a program with no
known bounds scan a backwards range. The port returns `pc + maximumLabelSearch`.

**The coroutine scheduler needed repairs to compile at all**: its C++ form passed four
initializers to a three-field struct, called `pc->op` with three of its four arguments, and used
`environment->memory` where a pointer was wanted. Its "skip to the next runnable context" step
was also recursive, and overflowed the stack once every context had finished; the port loops
instead and returns null.

**`ffi_cif` is opaque.** Its size is not knowable from D, because the C header ends it with an
arch-specific macro. Mizu hands libffi a fixed, generously sized, aligned byte buffer and never
looks inside. As a side effect the port owns the argument-type array outright, instead of
recovering it from `cif->arg_types - 1` to free it.

**`generate_header_file` generates D**, naturally, and is called `generateSourceFile`.

**`unsafe.allocateFatPointer` records a byte count**, not an element count. The C++ reached
libfp's internal `__fp_realloc(p, size, n)`; libfp's D API only takes the element size as a
template parameter, so a runtime element size has to become a total byte count.

### Not ported

**The WASM FFI trampoline.** The C++ FFI had a second backend for WebAssembly, built at compile
time by a generator (`ffi/wasm/generator.cpp.in` in the C++ repository) that emitted a
`calls.hpp`. That generator is a C++ program emitting C++, so there is nothing to translate;
`mizu.ffi.instructions` binds libffi only. With `MizuNoLibFFI` set the type-stack instructions still work and the call instructions
abort, so the shape is there if someone wants to fill it in.

**`stack_load_f32`/`stack_store_f32`** and their `f64` counterparts, which were commented out in
the C++ headers and never registered. Registers are raw 64-bit blobs, so `stackLoadU64` already
does the job.

## Licence

MIT, as the original. See [LICENSE](LICENSE).
