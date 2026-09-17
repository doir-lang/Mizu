/**
* Thin wrapper over the platform's dynamic loader (`dlopen`/`dlsym` on POSIX,
* `LoadLibrary`/`GetProcAddress` on Windows).
*
* The C++ original signalled failure by throwing `mizu::loader::error`, and
* `load_first_that_exists` caught it in a loop. `-betterC` has no exceptions,
* so every function here returns null on failure and leaves the reason in
* `lastError`, which is what lets `loadFirstThatExists` keep its "try each in
* turn" behaviour without a `try`/`catch`.
*/
module mizu.ffi.loader;

import fp.string : makeDynamicSlice, concatenateSlice, stringFree = free;

import mizu.config : dynamicLoadingSupported;

@nogc nothrow:

version(Posix) {
	import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, dlerror, RTLD_LAZY;
} else version(Windows) {
	import core.sys.windows.winbase : LoadLibraryA, GetProcAddress, FreeLibrary, GetModuleFileNameA;
	import core.sys.windows.windef : HMODULE;
}

/// An opaque handle to a loaded shared library.
struct Library;

/// The reason the most recent call failed, or null. Not thread safe.
__gshared const(char)* lastError = null;

private void* fail(const(char)* reason) {
	lastError = reason;
	return null;
}

/// The platform's extension for shared libraries, including the dot.
version(linux) enum string sharedLibraryExtension = ".so";
else version(FreeBSD) enum string sharedLibraryExtension = ".so";
else version(OSX) enum string sharedLibraryExtension = ".dylib";
else version(Windows) enum string sharedLibraryExtension = ".dll";
else enum string sharedLibraryExtension = "";

/**
* Loads a shared library.
*
* Params:
*   path = path to the library; most platforms also search their library path
*   appendPlatformDecorator = append `sharedLibraryExtension` to `path` first
* Returns: the library, or null (see `lastError`).
*/
Library* loadShared(scope const(char)[] path, bool appendPlatformDecorator = false) @trusted {
	static if (!dynamicLoadingSupported)
		return cast(Library*) fail("Dynamic loading is not supported on this platform.");
	else {
		// dlopen/LoadLibraryA want a C string, and `path` may be a slice, so
		// build the (optionally decorated) name as a libfp string. libfp keeps
		// the byte past the end of a string zeroed, so it is already NUL
		// terminated; an empty one is null, which `dlopen` would read as "the
		// current executable", hence the length check.
		if (path.length == 0)
			return cast(Library*) fail("Library path is empty.");

		char* name = makeDynamicSlice(path);
		if (name is null)
			return cast(Library*) fail("Failed to allocate the library's path.");
		scope(exit) stringFree(name);

		if (appendPlatformDecorator && sharedLibraryExtension.length)
			concatenateSlice(name, sharedLibraryExtension);
		// `concatenateSlice` only ever grows `name`, so this holds; it is
		// worth stating because `dlopen(null)` does not fail, it loads the
		// current executable, which would be a silent wrong answer.
		assert(name !is null);

		version(Posix) {
			auto result = dlopen(name, RTLD_LAZY);
			if (result is null) return cast(Library*) fail(dlerror());
			return cast(Library*) result;
		} else version(Windows) {
			auto result = LoadLibraryA(name);
			if (result is null) return cast(Library*) fail("Failed to load library.");
			return cast(Library*) result;
		}
	}
}

/// Ditto
alias loadDynamic = loadShared;
/// Ditto
alias loadLibrary = loadShared;

/**
* Tries each path in turn and returns the first library that loads.
*
* Returns: the library, or null (see `lastError`).
*/
Library* loadFirstThatExists(scope const(const(char)[])[] paths, bool appendPlatformDecorator = false) {
	foreach (path; paths)
		if (auto library = loadShared(path, appendPlatformDecorator))
			return library;
	return cast(Library*) fail("Failed to load any of the provided libraries!");
}

/**
* Loads the currently running executable, so `lookup` can find symbols the
* host application itself exports.
*
* Note:
*   On POSIX the host must be linked with `--export-dynamic` for its symbols
*   to be visible. Windows has no equivalent of `dlopen(null)`, so the
*   executable's own path is looked up and loaded by name instead; only the
*   symbols it explicitly exports are visible.
*
* Returns: the library, or null (see `lastError`).
*/
Library* loadCurrentExecutable() @trusted {
	version(Posix) {
		auto result = dlopen(null, RTLD_LAZY);
		if (result is null) return cast(Library*) fail(dlerror());
		return cast(Library*) result;
	} else version(Windows) {
		// The executable is already in the process, so loading it by name just
		// hands back its module handle (with one more reference, which keeps
		// `close` symmetrical with the other loaders).
		char[1024] buffer;
		immutable length = GetModuleFileNameA(null, buffer.ptr, cast(uint) buffer.length);
		if (length == 0 || length >= buffer.length)
			return cast(Library*) fail("Failed to determine the current executable's path.");
		buffer[length] = '\0';

		auto result = LoadLibraryA(buffer.ptr);
		if (result is null) return cast(Library*) fail("Failed to load the current executable.");
		return cast(Library*) result;
	} else
		return cast(Library*) fail("Dynamic loading is not supported on this platform.");
}

/**
* Finds a symbol.
*
* Params:
*   name = the symbol's (mangled) name
*   library = the library to search, or null for the current executable
* Returns: the symbol's address, or null (see `lastError`).
*/
void* lookup(scope const(char)* name, Library* library = null) @trusted {
	static if (!dynamicLoadingSupported)
		return fail("Dynamic loading is not supported on this platform.");
	else version(Posix) {
		// A null library means "search the whole process", which `dlsym`
		// spells as `RTLD_DEFAULT`. glibc defines that as a null handle, so
		// the argument passes straight through; macOS defines it as
		// `(void*) -2` and rejects a genuinely null handle outright.
		version(OSX) enum searchEverything = cast(Library*) -2;
		else enum searchEverything = cast(Library*) null;

		dlerror(); // Clear any stale error so ours is the only one we can see.
		auto result = dlsym(library is null ? searchEverything : library, name);
		if (auto error = dlerror()) return fail(error);
		return result;
	} else version(Windows) {
		// `loadCurrentExecutable` hands back a reference of its own, so release
		// it again rather than leaking one per lookup.
		auto handle = cast(HMODULE) library;
		if (handle is null) {
			auto self = loadCurrentExecutable();
			if (self is null) return null;
			handle = cast(HMODULE) self;
		}
		auto result = GetProcAddress(handle, name);
		if (library is null) FreeLibrary(handle);
		if (result is null) return fail("Failed to find function.");
		return cast(void*) result;
	}
}

/// Closes a library. Returns false on failure (see `lastError`).
bool close(Library* library) @trusted {
	static if (!dynamicLoadingSupported)
		return cast(bool) fail("Dynamic loading is not supported on this platform.");
	else version(Posix) {
		dlerror();
		dlclose(library);
		if (auto error = dlerror()) { lastError = error; return false; }
		return true;
	} else version(Windows) {
		if (!FreeLibrary(cast(HMODULE) library)) {
			lastError = "Failed to close library.";
			return false;
		}
		return true;
	}
}

version(unittest) {
	/**
	* A symbol for `loadCurrentExecutable`'s test to look up.
	*
	* Windows exposes only what an executable's export table names, so
	* `loadCurrentExecutable` there can find nothing unless something is
	* exported; POSIX publishes this alongside everything else through
	* `--export-dynamic`, so one symbol serves both.
	*/
	export extern(C) void mizuLoaderTestSymbol() {}

	/**
	* Names the C library answers to, in the order worth trying.
	*
	* Every platform has one, and none of these is a real path, so a test
	* using them exercises the loader's own search rather than just opening a
	* file it was handed.
	*/
	version(Windows)
		private immutable const(char)[][2] cRuntimeNames = ["msvcrt", "ucrtbase"];
	else
		private immutable const(char)[][3] cRuntimeNames =
			["libc.so.6", "libSystem.B.dylib", "libc"];
}

unittest {
	// The C library is present under at least one of these names everywhere
	// this test runs. Both spellings are tried unconditionally so the
	// decorated path is exercised even on the platforms where the undecorated
	// one already works.
	auto plain = loadFirstThatExists(cRuntimeNames[], false);
	auto decorated = loadFirstThatExists(cRuntimeNames[], true);
	scope(exit) if (plain !is null) close(plain);
	scope(exit) if (decorated !is null) close(decorated);

	auto library = plain !is null ? plain : decorated;
	assert(library !is null);

	// A symbol that exists, and one that does not.
	assert(lookup("malloc", library) !is null);
	assert(lookup("mizu_definitely_not_a_symbol", library) is null);
	assert(lastError !is null);
}

unittest {
	// Every way of failing to load a library: a name that is not one, the
	// same with the platform's extension appended, an empty path, and a list
	// in which nothing works.
	assert(loadShared("mizu_definitely_not_a_library", false) is null);
	assert(lastError !is null);
	assert(loadShared("mizu_definitely_not_a_library", true) is null);

	assert(loadShared("", false) is null);
	assert(lastError !is null);

	static immutable const(char)[][2] nothing = [
		"mizu_no_such_library_a", "mizu_no_such_library_b",
	];
	assert(loadFirstThatExists(nothing[], false) is null);
	assert(lastError !is null);
}

unittest {
	// The allocation for the library's path being refused. `loadShared` has
	// to build a NUL terminated copy of `path` before it can hand it to the
	// platform, and libfp's allocator is a plain global, so the failure can be
	// staged rather than waited for.
	import fp.pointer : allocFunction, AllocFunction;

	static AllocFunction previous;
	static void* refuse(void* p, size_t size) @nogc nothrow {
		if (size == 0) return previous(p, 0); // Still let callers clean up.
		return null;
	}

	previous = allocFunction;
	allocFunction = &refuse;
	auto library = loadShared("libc.so.6", false);
	allocFunction = previous;

	assert(library is null);
	assert(lastError !is null);
}

version(Windows)
unittest {
	// `close` failing. `FreeLibrary` rejects a null module handle and says so,
	// which is the only way to reach that branch without corrupting something
	// real. POSIX has no equivalent: `dlclose` of a handle it never issued is
	// undefined rather than an error, so this stays Windows only.
	assert(!close(null));
	assert(lastError !is null);
}

unittest {
	// The host executable loads by itself, and its own exported symbols are
	// visible through it — which is what lets the FFI call into the host.
	auto self = loadCurrentExecutable();
	assert(self !is null);
	scope(exit) close(self);
	assert(lookup("mizuLoaderTestSymbol", self) !is null);

	// A null library means the same thing, reached by a different route on
	// Windows (there is no `dlopen(null)`, so `lookup` loads the executable
	// itself and releases it again).
	assert(lookup("mizuLoaderTestSymbol", null) !is null);
}
