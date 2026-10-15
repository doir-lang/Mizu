/**
* Compile-time configuration knobs for Mizu.
*
* D has no equivalent of `-DNAME=value`, so the numeric knobs live here as plain `enum`s (edit them, or override the module in your own source tree), while the boolean knobs are D `version` identifiers, which `dub` can set for you:
*
* ---
* "versions": ["MizuNoHardwareThreads", "MizuEnableTracing"]
* ---
*
* $(UL
*   $(LI `MizuNoHardwareThreads`: emulate threads with a round-robin coroutine scheduler instead of using OS threads. Implied wherever bc-threads has no threads, such as wasm built without atomics.)
*   $(LI `MizuEnableTracing`: every instruction prints its name and operands as it runs.)
*   $(LI `MizuNoFFI`: drop the foreign function interface entirely.)
*   $(LI `MizuNoLibFFI`: keep the FFI instructions but do not bind libffi; unless `MizuFFITrampolines` gives them a backend, `createInterface` and the calls then abort.)
*   $(LI `MizuFFITrampolines`: make foreign calls through a trampoline generated at compile time for each signature, rather than libffi, which then is not bound. Implied on WASM, where libffi has no WASI port.)
*   $(LI `MizuAllowDMD`: let DMD compile these sources, which `mizu.opcode` otherwise refuses, for tools that only analyse them, never for something meant to run. libfp refuses DMD too, so pair it with `FpAllowDMD`.))
*/
module mizu.config;

static import bc.platform;

@nogc nothrow:

/// Size of a Mizu environment's memory (registers + stack) in kilobytes.
enum double stackSizeKilobytes = 8.0;

/// How many arguments a foreign call may take when `ffiTrampolines` is set. Each argument more multiplies the trampolines compiled in by four, so 4 makes 2046 of them.
enum size_t maximumTrampolineArguments = 4;

/// How many instructions `findLabel` may scan in either direction when the environment does not know where the program starts and ends.
enum size_t maximumLabelSearch = 1024;

version(WebAssembly) private enum bool isWasm = true;
else version(Emscripten) private enum bool isWasm = true;
else private enum bool isWasm = false;

/// True when threading instructions are emulated with coroutines rather than backed by real OS threads.
version(MizuNoHardwareThreads) enum bool noHardwareThreads = true;
else enum bool noHardwareThreads = !bc.platform.threadingSupported;

/// True when every instruction should trace itself to stdout as it runs.
version(MizuEnableTracing) enum bool enableTracing = true;
else enum bool enableTracing = false;

/// True when the foreign function interface is compiled out.
version(MizuNoFFI) enum bool noFFI = true;
else enum bool noFFI = false;

/// True when foreign calls go through the trampolines in `mizu.ffi.trampoline` rather than libffi.
version(MizuFFITrampolines) enum bool ffiTrampolines = true;
else enum bool ffiTrampolines = isWasm;

/// True when the FFI instructions are present but have no libffi behind them, either because `ffiTrampolines` replaces it or because there is no backend at all.
version(MizuNoLibFFI) enum bool noLibFFI = true;
else enum bool noLibFFI = ffiTrampolines;

/// True when DMD is allowed to compile Mizu despite being unable to produce a working one; see the `static assert` in `mizu.opcode`.
version(MizuAllowDMD) enum bool allowDMD = true;
else enum bool allowDMD = false;

/// True when the platform has a dynamic loader: `dlopen` on every Posix but WASI, `LoadLibrary` on Windows.
version(WASI) enum bool dynamicLoadingSupported = false;
else version(Posix) enum bool dynamicLoadingSupported = true;
else version(Windows) enum bool dynamicLoadingSupported = true;
else enum bool dynamicLoadingSupported = false;
