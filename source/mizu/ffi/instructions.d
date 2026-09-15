/**
* Foreign function interface instructions: Mizu calls a host function the
* same way it calls one of its own, substituting `ffi.call` for `jumpTo`.
*
* Describing a signature is a two-step dance, unchanged from the C++ version:
* push the return type and then each argument type onto a per-thread type
* stack, then `createInterface` turns that stack into a reusable interface
* handle. `call`/`callWithReturn` read the arguments out of the argument
* registers (`a0`, `a1`, ...).
*
* Note:
*   The C++ version had a second backend for WASM: a trampoline that its build
*   generated from `ffi/wasm/generator.cpp.in` (in the C++ repository, not this
*   one) into a `calls.hpp`. That generator is a C++ program emitting C++, so
*   there is nothing for a D port to reuse and this module binds libffi only.
*   With `MizuNoLibFFI` set (implied on WASM) the type-stack instructions still
*   work but `createInterface` and the two `call` instructions abort.
*/
module mizu.ffi.instructions;


import fp.dynarray : dynClear = clear, dynFree = free, length, pushBack;
import fp.pointer : fpMalloc = malloc, fpFree = free;

import mizu.config : noLibFFI;
import mizu.exception : fatal;
import mizu.ffi.loader;
import mizu.opcode;

static if (!noLibFFI) import mizu.ffi.libffi;

@nogc nothrow:

static if (!noLibFFI) {
	/**
	* The type stack the `pushType*` instructions build up.
	*
	* Thread local, like the C++ `thread_local` original, so two Mizu threads
	* can describe two signatures at once.
	*/
	private ffi_type** currentTypes = null;

	/**
	* A prepared call interface.
	*
	* Mizu owns the type array (unlike the C++ version, which reached back into
	* libffi's `cif->arg_types - 1` to free it) and keeps libffi's `ffi_cif` as
	* opaque bytes, since its size is not knowable from D.
	*/
	private struct Interface {
		/// `[0]` is the return type, the rest are arguments. An fp dynarray.
		ffi_type** types;
		/// How many arguments the function takes.
		uint argumentCount;
		/// Opaque storage for libffi's `ffi_cif`.
		align(16) ubyte[cifStorageBytes] cif;
	}
}

/**
* Releases this thread's type stack.
*
* `clearTypeStack` only empties the stack, keeping its capacity for the next
* signature, so a thread that pushed any type still owns a buffer when it
* ends. Nothing else frees it: the only other way the stack changes hands is
* `createInterface` taking ownership of it. `mizu.instructions.parallel` calls
* this as each forked thread finishes, which is why it is `package` rather
* than an instruction — a Mizu program cannot name it.
*
* The main thread's stack is left alone, and released by the process exiting.
*/
package(mizu) void releaseTypeStack() {
	static if (!noLibFFI)
		if (currentTypes !is null) dynFree(currentTypes);
}

/**
* Shared body of `call` and `callWithReturn`.
*
* Params:
*   hasReturn = whether the called function's result should be stored in `out_`
*/
private void* callImpl(bool hasReturn)(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (noLibFFI)
		fatal("This build of Mizu has no FFI backend (MizuNoLibFFI).");
	else {
		auto func = cast(void*) registers[pc.a];
		auto iface = cast(Interface*) registers[pc.b];
		if (iface is null) fatal("FFI Interface does not exist!");

		// libffi wants an array of pointers *to* the arguments, and Mizu keeps
		// the arguments in its argument registers, so point at those directly.
		void*[128] arguments;
		if (iface.argumentCount > arguments.length)
			fatal("Too many FFI arguments: ", iface.argumentCount);
		foreach (i; 0 .. iface.argumentCount)
			arguments[i] = &registers[Registers.a(i)];

		static if (hasReturn)
			ffi_call(iface.cif.ptr, func, &registers[pc.out_], arguments.ptr);
		else
			ffi_call(iface.cif.ptr, func, null, arguments.ptr);
	}
	mixin(mizuNext);
}

/// Pushes one type descriptor onto the current type stack.
private void pushType(string typeName)() {
	static if (!noLibFFI)
		pushBack(currentTypes, &mixin("ffi_type_" ~ typeName));
}

extern(C):

/// Adds `void` to the current type stack.
void* pushTypeVoid(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"void"();
	mixin(mizuNext);
}

/// Adds `void*` to the current type stack.
void* pushTypePointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"pointer"();
	mixin(mizuNext);
}

/// Adds `int32_t` to the current type stack.
void* pushTypeI32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"sint32"();
	mixin(mizuNext);
}

/// Adds `uint32_t` to the current type stack.
void* pushTypeU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"uint32"();
	mixin(mizuNext);
}

/// Adds `int64_t` to the current type stack.
void* pushTypeI64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"sint64"();
	mixin(mizuNext);
}

/// Adds `uint64_t` to the current type stack.
void* pushTypeU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"uint64"();
	mixin(mizuNext);
}

/// Adds `float` to the current type stack.
void* pushTypeF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"float"();
	mixin(mizuNext);
}

/// Adds `double` to the current type stack.
void* pushTypeF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"double"();
	mixin(mizuNext);
}

/// Clears the current type stack.
void* clearTypeStack(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noLibFFI) dynClear(currentTypes);
	mixin(mizuNext);
}

/**
* Converts the current type stack into an interface describing a function's
* signature, then clears the stack.
*
* Note:
*   The first type on the stack is the return type and everything after it is
*   a parameter. That return type is mandatory — use `pushTypeVoid` for a
*   function that returns nothing.
*
* Params:
*   out_ = register to store the resulting interface in
*/
void* createInterface(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (noLibFFI)
		fatal("This build of Mizu has no FFI backend (MizuNoLibFFI).");
	else {
		if (length(currentTypes) == 0)
			fatal("Function interfaces must at least specify the return type!");

		auto iface = fpMalloc!Interface(1);
		if (iface is null) fatal("Failed to allocate an FFI interface.");
		*iface = Interface.init;
		iface.types = currentTypes;
		iface.argumentCount = cast(uint)(length(currentTypes) - 1);

		immutable status = ffi_prep_cif(iface.cif.ptr, defaultAbi, iface.argumentCount,
			iface.types[0], iface.types + 1);
		if (status != ffi_status.FFI_OK)
			fatal("ffi_prep_cif failed: ", status);

		// The interface now owns the type array, so start a fresh stack rather
		// than clearing the one we just handed over.
		currentTypes = null;
		registers[pc.out_] = cast(size_t) iface;
	}
	mixin(mizuNext);
}

/**
* Frees an interface created by `createInterface`.
*
* Params:
*   a = register holding the interface to free
*   b = register holding a value to overwrite `a` with (defaults to zero)
*/
void* freeInterface(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noLibFFI) {
		auto iface = cast(Interface*) registers[pc.a];
		if (iface is null) fatal("FFI Interface does not exist!");
		if (iface.types !is null) dynFree(iface.types);
		fpFree(iface);
	}
	registers[pc.a] = registers[pc.b];
	mixin(mizuNext);
}

/**
* Calls a foreign function, discarding its result. The function's arguments
* are read from the argument registers (`a0`, `a1`, ...).
*
* Params:
*   a = register holding a pointer to the function to call
*   b = register holding the interface describing the function's signature
*/
void* call(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	return callImpl!false(pc, registers, env, sp);
}

/**
* Calls a foreign function and keeps its result. The function's arguments are
* read from the argument registers (`a0`, `a1`, ...).
*
* Params:
*   out_ = register to store the function's return value in
*   a = register holding a pointer to the function to call
*   b = register holding the interface describing the function's signature
*/
void* callWithReturn(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	return callImpl!true(pc, registers, env, sp);
}

/**
* Loads a shared library. Tries the path as given, then with the platform's
* extension appended.
*
* Params:
*   out_ = register to store the resulting library pointer in
*   a = register holding a null terminated path to search for
*/
void* loadLibrary(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	import core.stdc.string : strlen;
	auto path = cast(const(char)*) registers[pc.a];
	auto pathSlice = path[0 .. strlen(path)];

	auto library = loadShared(pathSlice, false);
	if (library is null) library = loadShared(pathSlice, true);
	registers[pc.out_] = cast(size_t) library;
	mixin(mizuNext);
}

/**
* Tries each of a list of libraries and keeps the first that loads. The paths
* are read from the first `immediate` argument registers.
*
* Params:
*   out_ = register to store the resulting library pointer in
*   immediate = how many argument registers (`a0`, `a1`, ...) hold paths
*/
void* loadFirstLibraryThatExists(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	import core.stdc.string : strlen;
	immutable count = pc.immediate;

	const(char)[][126] paths;
	if (count > paths.length) fatal("Too many library paths: ", count);
	foreach (i; 0 .. count) {
		auto path = cast(const(char)*) registers[Registers.a(i)];
		paths[i] = path[0 .. strlen(path)];
	}

	auto library = loadFirstThatExists(paths[0 .. count], false);
	if (library is null) library = loadFirstThatExists(paths[0 .. count], true);
	registers[pc.out_] = cast(size_t) library;
	mixin(mizuNext);
}

/**
* Loads a function pointer out of a library.
*
* Params:
*   out_ = register to store the resulting function pointer in
*   a = register holding the library to search, or zero for the host executable
*   b = register holding the function's null terminated (mangled) name
*/
void* loadLibraryFunction(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto library = cast(Library*) registers[pc.a];
	auto name = cast(const(char)*) registers[pc.b];
	registers[pc.out_] = cast(size_t) lookup(name, library);
	mixin(mizuNext);
}
