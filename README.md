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

* **LDC.** This is not a preference, and building with DMD is a compile-time error. See
  [Tail calls](#tail-calls) below.
* **An optimizing build** (`-O1` or higher). Also not a preference.
* **libffi**, unless you build with `-version=MizuNoFFI` or `-version=MizuFFITrampolines`. Any reasonably recent version works;
  Mizu declares the handful of entry points it needs itself. Windows does not ship one; see
  [libffi on Windows](#libffi-on-windows).

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

### Adding your own instructions

Write them in a module of your own, then build a lookup table that knows about both halves:

```d
module myproject.instructions;

import mizu;

extern(C) void* myInstruction(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @nogc nothrow {
    registers[pc.out_] = registers[pc.a] + 1;
    mixin(mizuNext);
}

/// Mizu's instructions, with this module's appended.
alias myLookup = Lookup!(myproject.instructions);
```

`myLookup` has the same members as `mizu.lookup` itself — `table`, `lookupId`, `lookupName`,
`lookupPointer`, `lookup` — with Mizu's IDs unchanged and yours starting at
`myLookup.builtinCount`. Names are stored fully qualified, so yours is
`myproject.instructions.myInstruction` and nothing collides with Mizu's own; `lookupId` still
takes a bare `myInstruction` when there is no ambiguity to worry about. Pass the table to the
serializers so they resolve both halves:

```d
auto bytes = toPortable!myLookup(program, environment);
auto loaded = fromPortable!myLookup(bytes[0 .. ptrLength(bytes)]);
```

Every function in `mizu.serialize` and `mizu.portable_format` takes a lookup as its first
template argument and defaults to `Lookup!()`, so code that only uses Mizu's own instructions
needs no changes.

This is a template rather than, say, a list of modules `mizu.lookup` imports, because Mizu is
normally compiled as its own static library — long before your instructions exist. A template is
instantiated in *your* compilation instead, where the compiler can see both halves, and the table
is still built entirely at compile time.

## Building this repository

```sh
dub build --config=library --compiler=ldc2    # the static library
dub test --compiler=ldc2                     # unit tests + end-to-end VM tests
dub run -c example-fib --compiler=ldc2        # recursive Fibonacci
dub run -c example-bubble --compiler=ldc2     # bubble sort on Mizu's stack
dub run -c example-threads --compiler=ldc2    # forked thread + channel + FFI call
dub run -c example-triangle --compiler=ldc2   # a GLFW/OpenGL triangle, entirely over the FFI
```

`--compiler=ldc2` is not a suggestion, and [source/mizu/opcode.d](source/mizu/opcode.d) enforces
it: under DMD it is a `static assert` rather than a build that fails later and less clearly. DMD
does not link the test suite at all — it emits calls to druntime helpers (`_memset128ii`,
`core.bitop.byteswap`) that `-betterC` then refuses to link against — and even if it did, it
performs no tail call optimization, so the dispatch described under [Tail calls](#tail-calls)
would overflow the stack on the first loop of any size. That applies to the coverage build too, so
`DC=dmd python3 tools/coverage.py` reports the same error rather than dying partway through the run.
`-version=MizuAllowDMD` lowers the error back to a warning, for tools that only analyse these
sources — `dmd -o-` syntax checks, ddoc — and never run what they build. libfp, which Mizu
depends on through bc-threads, refuses DMD the same way, so such a run also needs
`-version=FpAllowDMD`.

### libffi on Windows

Linux and macOS have libffi in their package managers (`apt install libffi-dev`, `brew install
libffi`). Windows has nothing to install, so build one with vcpkg before any of the commands
above:

```pwsh
tools/vcpkg-libffi.ps1
```

The script installs what [vcpkg.json](vcpkg.json) asks for, using whichever vcpkg it can find
(`VCPKG_ROOT`, `VCPKG_INSTALLATION_ROOT`, or one on `PATH`) and cloning one into `.vcpkg/vcpkg`
if there is none. It then stages the result as `.vcpkg/lib/ffi.lib`, which is where
`lflags-windows` in [dub.json](dub.json) and [tools/coverage.py](tools/coverage.py) point the
linker. Run it again whenever you want a newer libffi; it is otherwise a one-time step, and
everything it writes is git-ignored.

libffi's x64 assembly goes through MASM, so this needs the same Visual Studio build tools LDC
already links through. If you have a libffi from somewhere else, putting its `ffi.lib` on `LIB`
works just as well: the staged directory is searched first and simply contributes nothing when
it is empty.

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
python3 tools/coverage.py        # per-module summary
python3 tools/coverage.py -v     # ... and every uncovered line
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

### WebAssembly

```sh
python3 tools/wasi.py --serve                      # build for wasm32-wasi with threads and serve a page that runs the tests in a browser
python3 tools/wasi.py --node                       # build and run the same tests headlessly under Node
python3 tools/wasi.py --node --single-threaded     # the same without threads, testing the coroutine scheduler
```

This is bc-threads' WASI harness, adapted. bc-threads enables threads on WASI exactly when the
target has atomics, and `mizu.config` follows it: the threaded build compiles with
`-mattr=+atomics,+bulk-memory` and links against [wasi-sdk](https://github.com/WebAssembly/wasi-sdk)'s
`wasm32-wasip1-threads` libc with a shared, imported memory, while the single-threaded one gets
the coroutine scheduler, as `MizuNoHardwareThreads` would. Both builds are optimized and add
`+tail-call`; see [Tail calls](#tail-calls). The script downloads wasi-sdk into `bin/wasi-sdk` on
first use (or set `WASI_SYSROOT` and `WASI_BUILTINS`), and compiles bc-threads and libfp in from
the paths `dub describe` reports.

Threads need an LDC newer than 1.43: until
[ldc-developers/ldc#5268](https://github.com/ldc-developers/ldc/pull/5268), LDC compiled D's
thread-locals on wasm as ordinary globals, which every thread would share. The script checks for
this and refuses a threaded build with such a compiler; set `DC` to an LDC master build (CI uses
`ldc-master`), or pass `--single-threaded`.

The tests run through [@bjorn3/browser_wasi_shim](https://github.com/bjorn3/browser_wasi_shim)'s WASI and
[@emnapi/wasi-threads](https://github.com/toyobayashi/emnapi/tree/main/packages/wasi-threads),
which starts each thread on a Web Worker (or a Node worker thread); the script installs both into
`bin/wasi`, where the page and [tests/wasi/node.mjs](tests/wasi/node.mjs) import them alike. A
page may block only off its main thread, so [tests/wasi/run.mjs](tests/wasi/run.mjs) runs the
tests on a worker, and every thread reports its output and failures over a `BroadcastChannel`,
since the thread that would otherwise hear of them may be blocked joining. Shared memory also
needs a cross-origin isolated page, so `--serve` sends the `Cross-Origin-Opener-Policy` and
`Cross-Origin-Embedder-Policy` headers. Output arrives a line at a time, so a hung test shows the
module it stopped in but not the test index.

Foreign calls go through the trampoline backend (see [FFI trampolines](#ffi-trampolines)), but
WASI has no dynamic loader, so the tests that load libraries or look functions up by name are
skipped there. `abort` is a trap in wasm that
no handler can catch, so the checks that `fatal` really is reached are skipped too; a failed
assertion on any thread aborts, and the runner reports it as exit status 134.

### Profiling

```sh
DFLAGS="--frame-pointer=all" dub build -c example-fib --compiler=ldc2 --build=release-debug
perf record -F max --call-graph fp -e cpu_core/cycles/ -- ./bin/fib   # the program to profile
perf script --no-inline > perf.script
~/Dev/Packages/FlameGraph/stackcollapse-perf.pl perf.script > perf.folded
~/Dev/Packages/FlameGraph/flamegraph.pl perf.folded > perf.svg
```

`dub` appends `DFLAGS` to the build type's flags rather than replacing them, so the build keeps
its `-O3` and with it the tail calls.

`--frame-pointer=all` is what makes the profile readable, and it is not optional:
`--call-graph dwarf` against a build without it unwinds almost nothing to a real stack, leaves
most samples with no frames at all, throttles the sample period under the cost of copying
stacks, and writes gigabytes of `perf.data`. With frame pointers in the binary,
`--call-graph fp` needs none of that copying.

Expect a flat graph. Each instruction tail-calls the next, replacing its frame, so every
instruction shows up as a direct child of whatever called `startFromEnvironment` (in the
examples, `main`, which it is inlined into). The graph says what each instruction costs, not
which Mizu-level call path it ran on; that path lives in Mizu's registers and stack, where perf
cannot see it.

`-F max` because the examples are short: `fib` finishes in about 25ms, which at perf's default
rate is under twenty samples. Raise `target` in [examples/fib.d](examples/fib.d) for a longer
run.

`--no-inline` keeps `perf script` from expanding each address into the functions inlined there.
Without it, helpers such as `mizu.opcode.immediate` appear as children of the instruction that
inlined them, and the root of every stack is misattributed from `_start` to an unrelated inlined
function. Drop it when you want to see the inlined helpers.

`-e cpu_core/cycles/` because a hybrid CPU otherwise reports `cpu_atom` and `cpu_core` as two
events with their own sample periods, and anything that sums raw sample counts across them is
measuring nothing. On a CPU without separate core types, use `-e cycles`.

Check `kernel.perf_event_paranoid` before reading any of the numbers. At the default of 2 a run
can land a large share of its cycles on a single unresolvable `0xffffffff...` address, and that
time is simply invisible; `sudo sysctl kernel.perf_event_paranoid=1` attributes it.

`perf.script` for a run of any size is gigabytes, so stream it with `awk` rather than loading it,
and weight each sample by the period in its header line: once perf has throttled, that period is
not constant, and treating every sample as one unit silently reweights the profile.

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
`dub build` and `dub test` cannot accidentally produce a broken VM, and `mizu.opcode` refuses DMD at
compile time. If you build Mizu by hand, pass `-O2`.

WebAssembly also needs the `tail-call` feature (`-mattr=+tail-call`), which every current browser
and Node support. Unlike x86, LLVM's wasm backend will not duplicate a return block that several
paths share in order to tail-call from each, so an instruction that dispatches from more than one
place must funnel them into a single call, as `Coroutine.next` does.

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
| `MizuNoHardwareThreads` | Emulate threads with the round-robin coroutine scheduler. Implied wherever bc-threads has no threads, such as wasm built without atomics. |
| `MizuEnableTracing` | Every instruction prints its name and operands as it runs. |
| `MizuNoFFI` | Drop the FFI entirely, and with it the libffi dependency. |
| `MizuNoLibFFI` | Keep the FFI instructions but do not bind libffi; without `MizuFFITrampolines` the call instructions abort. |
| `MizuFFITrampolines` | Call through compile-time trampolines instead of libffi, which is then not needed. Implied on WASM. See [FFI trampolines](#ffi-trampolines). |
| `MizuAllowDMD` | Let DMD compile these sources, for tools that only analyse them; pair it with libfp's `FpAllowDMD`. See [Building this repository](#building-this-repository). |

D has no equivalent of `-DNAME=value`, so the two numeric knobs that used to be CMake cache
variables are `enum`s in [source/mizu/config.d](source/mizu/config.d):
`stackSizeKilobytes` (was `MIZU_STACK_SIZE`) and `maximumLabelSearch` (was
`MIZU_MAXIMUM_LABEL_SEARCH`). A third, `maximumTrampolineArguments`, is new to the port.

### FFI trampolines

libffi builds calls at run time from machine code, so it has no WASI port, and wasm's
`call_indirect` needs each signature fixed at compile time anyway.
[source/mizu/ffi/trampoline.d](source/mizu/ffi/trampoline.d) therefore generates, with CTFE, one
trampoline per signature, each casting the function pointer to that signature and calling it.
This replaces the C++ version's external generator (`ffi/wasm/generator.cpp.in`).

Only how a value is passed matters, so arguments fall into four classes (32 bit integer, 64 bit
integer, `float`, `double`) and results into six (adding `void` and the sign of a 32 bit result,
which is sign extended into the register as libffi does); pointers join whichever integer class
`size_t` does. Each argument more multiplies the table by four, so it is capped at
`mizu.config.maximumTrampolineArguments`, 4 by default, which compiles in 2046 trampolines;
`createInterface` treats a longer signature as fatal. On wasm a wrong signature traps in
`call_indirect` instead of corrupting anything.

The backend is also portable C ABI code, so `-version=MizuFFITrampolines` uses it on native
targets too, without linking libffi, which is how the two backends are checked against each other.
Function pointers have to come from the host on WASI, which has no dynamic loader: put them in a
register before running the program, as the examples in `mizu.ffi.instructions` do.

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
`release_lookup_data()` is gone, because there is nothing left to release. What the C++ bought
with that registration — a downstream project adding instructions of its own — comes instead
from `mizu.lookup.Lookup` being a template the downstream instantiates with its own modules; see
[Adding your own instructions](#adding-your-own-instructions).

**Exceptions are gone.** `MIZU_THROW` becomes `mizu.error.fatal`, which prints to `stderr`
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

**Instruction names are fully qualified.** The C++ registered each instruction under its bare
identifier, which was enough for a generated header that had already `#include`d everything.
`mizu.lookup` stores `mizu.instructions.core.add` instead, so two packages may each declare an
`add`, and a name says on its own where the instruction came from. `generateSourceFile` uses
that to write a file that names every instruction in full and imports exactly the modules the
program draws on — including a downstream package's — so the generated file compiles with no
help from the caller.

**`unsafe.allocateFatPointer` records a byte count**, not an element count. The C++ reached
libfp's internal `__fp_realloc(p, size, n)`; libfp's D API only takes the element size as a
template parameter, so a runtime element size has to become a total byte count.

### Not ported

**`stack_load_f32`/`stack_store_f32`** and their `f64` counterparts, which were commented out in
the C++ headers and never registered. Registers are raw 64-bit blobs, so `stackLoadU64` already
does the job.

## Licence

MIT, as the original. See [LICENSE](LICENSE).
