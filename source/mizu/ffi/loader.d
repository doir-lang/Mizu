/**
* Thin wrapper over the platform's dynamic loader (`dlopen`/`dlsym` on POSIX, `LoadLibrary`/`GetProcAddress` on Windows).
*
* `-betterC` has no exceptions, so where the C++ original threw, every function here returns null or false and leaves the reason in `lastError`, which is what lets `loadFirstThatExists` try each path in turn.
*/
module mizu.ffi.loader;

static import fp.string;

static import mizu.config;

@nogc nothrow:

version(Posix) {
	import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, dlerror, RTLD_LAZY;
} else version(Windows) {
	import core.sys.windows.winbase : LoadLibraryA, GetProcAddress, FreeLibrary, GetModuleFileNameA;
	import core.sys.windows.windef : HMODULE;
}

/// An opaque handle to a loaded shared library.
struct Library;

/**
* The reason the most recent call failed, or null. Not thread safe.
*
* Examples:
* ---
* assert(loadShared("") is null);
* assert(lastError !is null);
* ---
*/
__gshared const(char)* lastError = null;

private void* fail(const(char)* reason) {
	lastError = reason;
	return null;
}

/// The platform's extension for shared libraries, including the dot; `.so` is every Posix but Darwin.
version(OSX) enum string sharedLibraryExtension = ".dylib";
else version(Windows) enum string sharedLibraryExtension = ".dll";
else version(Posix) enum string sharedLibraryExtension = ".so";
else enum string sharedLibraryExtension = "";

/**
* Loads a shared library.
*
* Params:
*   path = path to the library; most platforms also search their library path
*   appendPlatformDecorator = append `sharedLibraryExtension` to `path` first
* Returns: the library, to release with `close`, or null (see `lastError`).
*
* Examples:
* ---
* version(linux) {
* 	Library* c = loadShared("libc.so.6");
* 	assert(c !is null);
* 	assert(close(c));
* }
* assert(loadShared("mizu_definitely_not_a_library", true) is null);
* ---
*/
Library* loadShared(scope const(char)[] path, bool appendPlatformDecorator = false) @trusted {
	static if (!mizu.config.dynamicLoadingSupported)
		return cast(Library*) fail("Dynamic loading is not supported on this platform.");
	else {
		// An empty path would become a null name, which `dlopen` reads as the current executable rather than failing.
		if (path.length == 0)
			return cast(Library*) fail("Library path is empty.");

		// libfp strings are NUL terminated, so this is the C string the platform wants.
		char* name = fp.string.makeDynamic(path);
		if (name is null)
			return cast(Library*) fail("Failed to allocate the library's path.");
		scope(exit) fp.string.free(name);

		if (appendPlatformDecorator && sharedLibraryExtension.length && fp.string.concatenate(name, sharedLibraryExtension) is null)
			return cast(Library*) fail("Failed to allocate the library's path.");

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
* Returns: the library, to release with `close`, or null (see `lastError`).
*
* Examples:
* ---
* static immutable const(char)[][3] names = ["libc.so.6", "libSystem.B.dylib", "msvcrt"];
* Library* c = loadFirstThatExists(names[]);
* assert(c !is null);
* assert(close(c));
* ---
*/
Library* loadFirstThatExists(scope const(const(char)[])[] paths, bool appendPlatformDecorator = false) {
	foreach (path; paths)
		if (auto library = loadShared(path, appendPlatformDecorator))
			return library;
	return cast(Library*) fail("Failed to load any of the provided libraries!");
}

/**
* Loads the currently running executable, so `lookup` can find symbols the host application itself exports.
*
* Note: on POSIX the host must be linked with `--export-dynamic` for its symbols to be visible. Windows has no `dlopen(null)`, so the executable is loaded by its own path instead, and only the symbols it explicitly exports are visible.
*
* Returns: the library, to release with `close`, or null (see `lastError`).
*
* Examples:
* ---
* Library* self = loadCurrentExecutable();
* assert(self !is null);
* assert(close(self));
* ---
*/
Library* loadCurrentExecutable() @trusted {
	version(Posix) {
		auto result = dlopen(null, RTLD_LAZY);
		if (result is null) return cast(Library*) fail(dlerror());
		return cast(Library*) result;
	} else version(Windows) {
		// Loading the running executable by name hands back its module handle with one more reference, keeping `close` symmetrical.
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
*
* Examples:
* ---
* static immutable const(char)[][3] names = ["libc.so.6", "libSystem.B.dylib", "msvcrt"];
* Library* c = loadFirstThatExists(names[]);
* scope(exit) cast(void) close(c);
* assert(lookup("malloc", c) !is null);
* assert(lookup("mizu_definitely_not_a_symbol", c) is null);
* ---
*/
void* lookup(scope const(char)* name, Library* library = null) @trusted {
	static if (!mizu.config.dynamicLoadingSupported)
		return fail("Dynamic loading is not supported on this platform.");
	else version(Posix) {
		// `RTLD_DEFAULT` searches the whole process: a null handle on glibc, but `(void*) -2` on macOS, which rejects null outright.
		version(OSX) enum searchEverything = cast(Library*) -2;
		else enum searchEverything = cast(Library*) null;

		cast(void) dlerror(); // Clear any stale error so ours is the only one we can see.
		auto result = dlsym(library is null ? searchEverything : library, name);
		if (auto error = dlerror()) return fail(error);
		return result;
	} else version(Windows) {
		// `loadCurrentExecutable` hands back a reference of its own, so release it rather than leaking one per lookup.
		auto handle = cast(HMODULE) library;
		if (handle is null) {
			auto self = loadCurrentExecutable();
			if (self is null) return null;
			handle = cast(HMODULE) self;
		}
		auto result = GetProcAddress(handle, name);
		// Only drops the reference taken just above, which cannot fail.
		if (library is null) cast(void) FreeLibrary(handle);
		if (result is null) return fail("Failed to find function.");
		return cast(void*) result;
	}
}

/**
* Closes a library a loader in this module returned. Returns false on failure (see `lastError`).
*
* Examples:
* ---
* Library* self = loadCurrentExecutable();
* assert(close(self));
* ---
*/
bool close(Library* library) @trusted {
	static if (!mizu.config.dynamicLoadingSupported)
		return cast(bool) fail("Dynamic loading is not supported on this platform.");
	else version(Posix) {
		cast(void) dlerror();
		cast(void) dlclose(library);
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
	static import fp.pointer;

	/**
	* A symbol for `loadCurrentExecutable`'s test to look up; Windows exposes only an executable's exports, and POSIX this too through `--export-dynamic`.
	*
	* Examples:
	* ---
	* mizuLoaderTestSymbol();
	* ---
	*/
	export extern(C) void mizuLoaderTestSymbol() {}

	// Names the C library answers to, none a real path, so tests exercise the loader's own search.
	version(Windows)
		private immutable const(char)[][2] cRuntimeNames = ["msvcrt", "ucrtbase"];
	else
		private immutable const(char)[][3] cRuntimeNames =
			["libc.so.6", "libSystem.B.dylib", "libc"];
}

static if (mizu.config.dynamicLoadingSupported)
unittest {
	// Both spellings are tried, so the decorated path runs even where the undecorated one already works.
	auto plain = loadFirstThatExists(cRuntimeNames[], false);
	auto decorated = loadFirstThatExists(cRuntimeNames[], true);
	scope(exit) if (plain !is null) assert(close(plain));
	scope(exit) if (decorated !is null) assert(close(decorated));

	auto library = plain !is null ? plain : decorated;
	assert(library !is null);

	// A symbol that exists, and one that does not.
	assert(lookup("malloc", library) !is null);
	assert(lookup("mizu_definitely_not_a_symbol", library) is null);
	assert(lastError !is null);
}

unittest {
	// Every way of failing to load a library: a bad name, with and without the extension, an empty path, and a hopeless list.
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
	// libfp's allocator is a plain global, so refusing the copy of the library's path can be staged.
	static fp.pointer.AllocFunction previous;
	static void* refuse(void* p, size_t size) @nogc nothrow {
		if (size == 0) return previous(p, 0); // Still let callers clean up.
		return null;
	}

	previous = fp.pointer.allocFunction;
	fp.pointer.allocFunction = &refuse;
	auto library = loadShared("libc.so.6", false);
	fp.pointer.allocFunction = previous;

	assert(library is null);
	assert(lastError !is null);
}

version(Windows)
unittest {
	// `FreeLibrary` rejects a null handle, but POSIX `dlclose` of a foreign handle is undefined, so only Windows can test failing to close.
	assert(!close(null));
	assert(lastError !is null);
}

static if (mizu.config.dynamicLoadingSupported)
unittest {
	// The host executable loads by itself, and its exported symbols are visible through it, which lets the FFI call into the host.
	auto self = loadCurrentExecutable();
	assert(self !is null);
	scope(exit) assert(close(self));
	assert(lookup("mizuLoaderTestSymbol", self) !is null);

	// A null library means the same thing, though Windows `lookup` reaches it by loading and releasing the executable itself.
	assert(lookup("mizuLoaderTestSymbol", null) !is null);
}
