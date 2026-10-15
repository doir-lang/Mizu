/**
* Foreign function interface instructions: Mizu calls a host function the same way it calls one of its own, substituting `call` for `jumpTo`.
*
* Describing a signature takes two steps: push the return type and then each argument type onto a per-thread type stack, then `createInterface` turns that stack into a reusable interface handle. `call`/`callWithReturn` read the arguments out of the argument registers (`a0`, `a1`, ...).
*
* Note: this module binds libffi only; the C++ version's generated WASM trampoline has no D counterpart. With `MizuNoLibFFI` set (implied on WASM) the type-stack instructions still work, but `createInterface` and the two `call` instructions abort.
*/
module mizu.ffi.instructions;

import core.stdc.string : strlen;

static import fp.dynarray;
static import fp.pointer;

static import mizu.config;
static import mizu.error;
static import mizu.ffi.loader;
import mizu.opcode;

static if (!mizu.config.noLibFFI) static import mizu.ffi.libffi;

@nogc nothrow:

static if (!mizu.config.noLibFFI) {
	// The type stack the `pushType*` instructions build up; thread local, so two Mizu threads can describe two signatures at once.
	private mizu.ffi.libffi.ffi_type** currentTypes = null;

	// A prepared call interface, owning its type array and holding libffi's `ffi_cif`, whose size D cannot know, as opaque bytes.
	private struct Interface {
		mizu.ffi.libffi.ffi_type** types; // `[0]` is the return type, the rest are arguments; an fp dynarray.
		uint argumentCount;
		align(16) ubyte[mizu.ffi.libffi.cifStorageBytes] cif;
	}
}

/**
* Releases this thread's type stack, which `clearTypeStack` only empties. `mizu.instructions.parallel` calls this as each forked thread finishes; the main thread's stack is released by the process exiting.
*
* Examples:
* ---
* mizu.ffi.instructions.releaseTypeStack();
* ---
*/
package(mizu) void releaseTypeStack() {
	static if (!mizu.config.noLibFFI)
		fp.dynarray.free(currentTypes);
}

// Shared body of `call` and `callWithReturn`; `hasReturn` stores the result in `out_`.
private void* callImpl(bool hasReturn)(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (mizu.config.noLibFFI)
		mizu.error.fatal("This build of Mizu has no FFI backend (MizuNoLibFFI).");
	else {
		auto func = cast(void*) registers[pc.a];
		auto iface = cast(Interface*) registers[pc.b];
		if (iface is null) mizu.error.fatal("FFI Interface does not exist!");

		// libffi wants pointers to the arguments, which already sit in the argument registers.
		void*[argumentCount] arguments;
		if (iface.argumentCount > arguments.length)
			mizu.error.fatal("Too many FFI arguments: ", iface.argumentCount);
		foreach (i; 0 .. iface.argumentCount)
			arguments[i] = &registers[Registers.a(i)];

		static if (hasReturn)
			mizu.ffi.libffi.ffi_call(iface.cif.ptr, func, &registers[pc.out_], arguments.ptr);
		else
			mizu.ffi.libffi.ffi_call(iface.cif.ptr, func, null, arguments.ptr);
	}
	mixin(mizuNext);
}

// Pushes one type descriptor onto the current type stack, aborting if it cannot grow.
private void pushType(string typeName)() {
	static if (!mizu.config.noLibFFI)
		if (!fp.dynarray.pushBack(currentTypes, &mixin("mizu.ffi.libffi.ffi_type_" ~ typeName)))
			mizu.error.fatal("Failed to grow the FFI type stack.");
}

extern(C):

/**
* Pushes `void` (meaningful only as the return type) onto this thread's FFI type stack, which `createInterface` turns into a signature: the first type pushed is the return type, the rest the parameters. Failing to grow the stack is fatal.
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeVoid),
* 	Opcode(&pushTypePointer),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&call, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* static int calls;
* static extern(C) void bump(int* counter) @nogc nothrow { ++*counter; }
* env.memory[Registers.t(0)] = cast(size_t) &bump;
* env.memory[Registers.a(0)] = cast(size_t) &calls;
* cast(void) startFromEnvironment(program[], env);
* assert(calls == 1);
* ---
*/
void* pushTypeVoid(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"void"();
	mixin(mizuNext);
}

/**
* Pushes `void*` onto this thread's FFI type stack, which `createInterface` turns into a signature: the first type pushed is the return type, the rest the parameters. Failing to grow the stack is fatal.
*
* Examples:
* ---
* import core.stdc.string : strlen;
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeU64),
* 	Opcode(&pushTypePointer),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) &strlen;
* env.memory[Registers.a(0)] = cast(size_t) "four".ptr;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 4);
* ---
*/
void* pushTypePointer(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"pointer"();
	mixin(mizuNext);
}

/**
* Pushes `int32_t` onto this thread's FFI type stack, which `createInterface` turns into a signature: the first type pushed is the return type, the rest the parameters. Failing to grow the stack is fatal.
*
* Examples:
* ---
* import core.stdc.stdlib : abs;
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeI32),
* 	Opcode(&pushTypeI32),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) &abs;
* *cast(int*) &env.memory[Registers.a(0)] = -42;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(int) env.memory[Registers.t(2)] == 42);
* ---
*/
void* pushTypeI32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"sint32"();
	mixin(mizuNext);
}

/**
* Pushes `uint32_t` onto this thread's FFI type stack, which `createInterface` turns into a signature: the first type pushed is the return type, the rest the parameters. Failing to grow the stack is fatal.
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeU32),
* 	Opcode(&pushTypeU32),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* static extern(C) uint twice(uint x) @nogc nothrow { return 2 * x; }
* env.memory[Registers.t(0)] = cast(size_t) &twice;
* env.memory[Registers.a(0)] = 21;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(uint) env.memory[Registers.t(2)] == 42);
* ---
*/
void* pushTypeU32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"uint32"();
	mixin(mizuNext);
}

/**
* Pushes `int64_t` onto this thread's FFI type stack, which `createInterface` turns into a signature: the first type pushed is the return type, the rest the parameters. Failing to grow the stack is fatal.
*
* Examples:
* ---
* import core.stdc.stdlib : llabs;
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeI64),
* 	Opcode(&pushTypeI64),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) &llabs;
* env.memory[Registers.a(0)] = -42;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
*/
void* pushTypeI64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"sint64"();
	mixin(mizuNext);
}

/**
* Pushes `uint64_t` onto this thread's FFI type stack, which `createInterface` turns into a signature: the first type pushed is the return type, the rest the parameters. Failing to grow the stack is fatal.
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeU64),
* 	Opcode(&pushTypeU64),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* static extern(C) ulong twice(ulong x) @nogc nothrow { return 2 * x; }
* env.memory[Registers.t(0)] = cast(size_t) &twice;
* env.memory[Registers.a(0)] = 1UL << 40;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 1UL << 41);
* ---
*/
void* pushTypeU64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"uint64"();
	mixin(mizuNext);
}

/**
* Pushes `float` onto this thread's FFI type stack, which `createInterface` turns into a signature: the first type pushed is the return type, the rest the parameters. Failing to grow the stack is fatal.
*
* Examples:
* ---
* import core.stdc.math : sqrtf;
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeF32),
* 	Opcode(&pushTypeF32),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) &sqrtf;
* floatRegister!float(env.memory.ptr, Registers.a(0)) = 1764;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!float(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* pushTypeF32(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"float"();
	mixin(mizuNext);
}

/**
* Pushes `double` onto this thread's FFI type stack, which `createInterface` turns into a signature: the first type pushed is the return type, the rest the parameters. Failing to grow the stack is fatal.
*
* Examples:
* ---
* import core.stdc.math : sqrt;
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeF64),
* 	Opcode(&pushTypeF64),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) &sqrt;
* floatRegister!double(env.memory.ptr, Registers.a(0)) = 1764;
* cast(void) startFromEnvironment(program[], env);
* assert(floatRegister!double(env.memory.ptr, Registers.t(2)) == 42);
* ---
*/
void* pushTypeF64(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	pushType!"double"();
	mixin(mizuNext);
}

/**
* Empties this thread's FFI type stack, keeping its capacity, to start a signature over.
*
* Examples:
* ---
* import core.stdc.stdlib : abs;
* static immutable Opcode[8] program = [
* 	Opcode(&pushTypeF64),
* 	Opcode(&clearTypeStack),
* 	Opcode(&pushTypeI32),
* 	Opcode(&pushTypeI32),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) &abs;
* *cast(int*) &env.memory[Registers.a(0)] = -42;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(int) env.memory[Registers.t(2)] == 42);
* ---
*/
void* clearTypeStack(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!mizu.config.noLibFFI) fp.dynarray.clear(currentTypes);
	mixin(mizuNext);
}

/**
* Converts this thread's type stack into an interface describing a function's signature, handing the stack over to it and leaving this thread's empty. An empty stack, or one libffi rejects, is fatal.
*
* The first type on the stack is the return type and everything after it is a parameter; use `pushTypeVoid` for a function that returns nothing.
*
* Params:
*   out_ = register to store the interface in, for `call`, `callWithReturn` and `freeInterface`
*
* Examples:
* ---
* import core.stdc.stdlib : abs;
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeI32),
* 	Opcode(&pushTypeI32),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) &abs;
* *cast(int*) &env.memory[Registers.a(0)] = -42;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(int) env.memory[Registers.t(2)] == 42);
* ---
*/
void* createInterface(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (mizu.config.noLibFFI)
		mizu.error.fatal("This build of Mizu has no FFI backend (MizuNoLibFFI).");
	else {
		if (fp.pointer.length(currentTypes) == 0)
			mizu.error.fatal("Function interfaces must at least specify the return type!");

		auto iface = fp.pointer.malloc!Interface(1);
		if (iface is null) mizu.error.fatal("Failed to allocate an FFI interface.");
		*iface = Interface.init;
		iface.types = currentTypes;
		iface.argumentCount = cast(uint)(fp.pointer.length(currentTypes) - 1);

		immutable status = mizu.ffi.libffi.ffi_prep_cif(iface.cif.ptr, mizu.ffi.libffi.defaultAbi, iface.argumentCount, iface.types[0], iface.types + 1);
		if (status != mizu.ffi.libffi.ffi_status.FFI_OK)
			mizu.error.fatal("ffi_prep_cif failed: ", status);

		// The interface owns the type array now, so start a fresh stack rather than clearing it.
		currentTypes = null;
		registers[pc.out_] = cast(size_t) iface;
	}
	mixin(mizuNext);
}

/**
* Frees an interface created by `createInterface`; a null one is fatal.
*
* Params:
*   a = register holding the interface to free, then overwritten with `b`
*   b = register holding the value to overwrite `a` with, usually `zero`
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&pushTypeVoid),
* 	Opcode(&createInterface, Registers.t(0)),
* 	Opcode(&freeInterface, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 0);
* ---
*/
void* freeInterface(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!mizu.config.noLibFFI) {
		auto iface = cast(Interface*) registers[pc.a];
		if (iface is null) mizu.error.fatal("FFI Interface does not exist!");
		fp.dynarray.free(iface.types);
		fp.pointer.free(iface);
	}
	registers[pc.a] = registers[pc.b];
	mixin(mizuNext);
}

/**
* Calls a foreign function, discarding its result. The function's arguments are read from the argument registers (`a0`, `a1`, ...), as many as the interface describes, at most `argumentCount`; more is fatal.
*
* Params:
*   a = register holding a pointer to the function to call
*   b = register holding the interface describing the function's signature
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeVoid),
* 	Opcode(&pushTypePointer),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&call, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* static int calls;
* static extern(C) void bump(int* counter) @nogc nothrow { ++*counter; }
* env.memory[Registers.t(0)] = cast(size_t) &bump;
* env.memory[Registers.a(0)] = cast(size_t) &calls;
* cast(void) startFromEnvironment(program[], env);
* assert(calls == 1);
* ---
*/
void* call(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	return callImpl!false(pc, registers, env, sp);
}

/**
* Calls a foreign function and keeps its result. The function's arguments are read from the argument registers (`a0`, `a1`, ...), as many as the interface describes, at most `argumentCount`; more is fatal.
*
* Params:
*   out_ = register to store the function's return value in
*   a = register holding a pointer to the function to call
*   b = register holding the interface describing the function's signature
*
* Examples:
* ---
* import core.stdc.stdlib : abs;
* static immutable Opcode[6] program = [
* 	Opcode(&pushTypeI32),
* 	Opcode(&pushTypeI32),
* 	Opcode(&createInterface, Registers.t(1)),
* 	Opcode(&callWithReturn, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&freeInterface, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) &abs;
* *cast(int*) &env.memory[Registers.a(0)] = -5;
* cast(void) startFromEnvironment(program[], env);
* assert(cast(int) env.memory[Registers.t(2)] == 5);
* ---
*/
void* callWithReturn(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	return callImpl!true(pc, registers, env, sp);
}

/**
* Loads a shared library, trying the path as given and then with the platform's extension appended.
*
* Params:
*   out_ = register to store the library in, for `loadLibraryFunction` and `mizu.ffi.loader.close`, or zero if neither loaded
*   a = register holding a pointer to the null terminated path
*
* Examples:
* ---
* version(linux) {
* 	static immutable Opcode[2] program = [
* 		Opcode(&loadLibrary, Registers.t(1), Registers.t(0)),
* 		Opcode(&halt),
* 	];
* 	RegistersAndStack env;
* 	setupEnvironment(env, program[]);
* 	env.memory[Registers.t(0)] = cast(size_t) "libc.so.6".ptr;
* 	cast(void) startFromEnvironment(program[], env);
* 	assert(env.memory[Registers.t(1)] != 0);
* 	assert(mizu.ffi.loader.close(cast(mizu.ffi.loader.Library*) env.memory[Registers.t(1)]));
* }
* ---
*/
void* loadLibrary(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto path = cast(const(char)*) registers[pc.a];
	auto pathSlice = path[0 .. strlen(path)];

	auto library = mizu.ffi.loader.loadShared(pathSlice, false);
	if (library is null) library = mizu.ffi.loader.loadShared(pathSlice, true);
	registers[pc.out_] = cast(size_t) library;
	mixin(mizuNext);
}

/**
* Tries each of a list of libraries, as given and then with the platform's extension appended, and keeps the first that loads.
*
* Params:
*   out_ = register to store the library in, for `loadLibraryFunction` and `mizu.ffi.loader.close`, or zero if none loaded
*   immediate = how many argument registers, from `a0` on, hold pointers to null terminated paths; at most `argumentCount`, and more is fatal
*
* Examples:
* ---
* static immutable Opcode[2] program = [
* 	Opcode(&loadFirstLibraryThatExists, Registers.t(0)).setImmediate(3),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.a(0)] = cast(size_t) "libc.so.6".ptr;
* env.memory[Registers.a(1)] = cast(size_t) "libSystem.B.dylib".ptr;
* env.memory[Registers.a(2)] = cast(size_t) "msvcrt".ptr;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] != 0);
* assert(mizu.ffi.loader.close(cast(mizu.ffi.loader.Library*) env.memory[Registers.t(0)]));
* ---
*/
void* loadFirstLibraryThatExists(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable count = immediate(*pc);

	const(char)[][argumentCount] paths;
	if (count > paths.length) mizu.error.fatal("Too many library paths: ", count);
	foreach (i; 0 .. count) {
		auto path = cast(const(char)*) registers[Registers.a(i)];
		paths[i] = path[0 .. strlen(path)];
	}

	auto library = mizu.ffi.loader.loadFirstThatExists(paths[0 .. count], false);
	if (library is null) library = mizu.ffi.loader.loadFirstThatExists(paths[0 .. count], true);
	registers[pc.out_] = cast(size_t) library;
	mixin(mizuNext);
}

/**
* Loads a function pointer out of a library.
*
* Params:
*   out_ = register to store the function pointer in, or zero if it was not found
*   a = register holding the library to search, or zero for the host executable
*   b = register holding a pointer to the function's null terminated (mangled) name
*
* Examples:
* ---
* static immutable const(char)[][3] names = ["libc.so.6", "libSystem.B.dylib", "msvcrt"];
* mizu.ffi.loader.Library* c = mizu.ffi.loader.loadFirstThatExists(names[]);
* scope(exit) cast(void) mizu.ffi.loader.close(c);
* static immutable Opcode[2] program = [
* 	Opcode(&loadLibraryFunction, Registers.t(2), Registers.t(0), Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* env.memory[Registers.t(0)] = cast(size_t) c;
* env.memory[Registers.t(1)] = cast(size_t) "abs".ptr;
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] != 0);
* ---
*/
void* loadLibraryFunction(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto library = cast(mizu.ffi.loader.Library*) registers[pc.a];
	auto name = cast(const(char)*) registers[pc.b];
	registers[pc.out_] = cast(size_t) mizu.ffi.loader.lookup(name, library);
	mixin(mizuNext);
}
