/**
* Compile-time configuration knobs for Mizu.
*
* The C++ original exposed these as CMake cache variables that became
* preprocessor defines. D has no equivalent of `-DNAME=value`, so the
* numeric knobs live here as plain `enum`s (edit them, or override the
* module in your own source tree), while the boolean knobs map cleanly onto
* D `version` identifiers, which `dub` can set for you:
*
* ---
* "versions": ["MizuNoHardwareThreads", "MizuEnableTracing"]
* ---
*
* $(UL
*   $(LI `MizuNoHardwareThreads` — emulate threads with a round-robin
*        coroutine scheduler instead of using OS threads. Implied on WASM.)
*   $(LI `MizuEnableTracing` — every instruction prints its name and
*        operands as it runs.)
*   $(LI `MizuNoFFI` — drop the foreign function interface entirely.)
*   $(LI `MizuNoLibFFI` — keep the FFI instructions but do not bind libffi;
*        `create_interface`/`call` then abort. Implied when libffi is
*        unavailable.))
*/
module mizu.config;

@nogc nothrow:

/// Size of a Mizu environment's memory (registers + stack) in kilobytes.
enum double stackSizeKilobytes = 8.0;

/// How many instructions `findLabel` may scan in either direction when the
/// environment does not know where the program starts and ends.
enum size_t maximumLabelSearch = 1024;

version(WebAssembly) private enum bool isWasm = true;
else version(Emscripten) private enum bool isWasm = true;
else private enum bool isWasm = false;

/// True when threading instructions are emulated with coroutines rather
/// than backed by real OS threads.
version(MizuNoHardwareThreads) enum bool noHardwareThreads = true;
else enum bool noHardwareThreads = isWasm;

/// True when every instruction should trace itself to stdout as it runs.
version(MizuEnableTracing) enum bool enableTracing = true;
else enum bool enableTracing = false;

/// True when the foreign function interface is compiled out.
version(MizuNoFFI) enum bool noFFI = true;
else enum bool noFFI = false;

/// True when the FFI instructions are present but have no libffi behind them.
version(MizuNoLibFFI) enum bool noLibFFI = true;
else enum bool noLibFFI = isWasm;

/// True when the platform has a dynamic loader (`dlopen`/`LoadLibrary`).
version(linux) enum bool dynamicLoadingSupported = true;
else version(OSX) enum bool dynamicLoadingSupported = true;
else version(FreeBSD) enum bool dynamicLoadingSupported = true;
else version(Windows) enum bool dynamicLoadingSupported = true;
else enum bool dynamicLoadingSupported = false;
