/**
* The FFI backend for targets without libffi, WebAssembly above all: a trampoline generated at compile time for every signature of up to `mizu.config.maximumTrampolineArguments` arguments, each calling through a function pointer cast to that signature.
*
* A call only depends on how each value is passed, so the eight Mizu types collapse to four argument classes (32 and 64 bit integers, `float`, `double`) and six return classes (which also keep `void` and the sign of a 32 bit result), and a pointer joins whichever integer class `size_t` does. That keeps the table to `6 * (1 + 4 + ... + 4^max)` entries. On wasm a function pointer is a table index and the call is a `call_indirect`, which traps rather than misbehaves if the signature is wrong.
*/
module mizu.ffi.trampoline;

static import mizu.config;

@nogc nothrow:

/// A type the `pushType*` instructions describe a signature with.
enum Kind : ubyte {
	void_,   /// `void`, meaningful only as the return type
	i32,     /// `int32_t`
	u32,     /// `uint32_t`
	i64,     /// `int64_t`
	u64,     /// `uint64_t`
	f32,     /// `float`
	f64,     /// `double`
	pointer, /// `void*`
}

/// Calls `func` as the signature the trampoline was made for, reading each argument from the start of its slot in `arguments` as libffi would, and storing the result in `*result`, sign extending a 32 bit signed one.
alias Trampoline = void function(const(void)* func, const(ulong)* arguments, ulong* result) @nogc nothrow;

// The D type each argument and return class calls with, in the order their digits number them.
private immutable string[4] argumentTypes = ["uint", "ulong", "float", "double"];
private immutable string[6] returnTypes = ["void", "int", "uint", "ulong", "float", "double"];

// Which entry of `argumentTypes` passes `kind`, or -1 for `void`, which is no argument.
private int argumentClass(Kind kind) {
	final switch (kind) {
		case Kind.void_: return -1;
		case Kind.i32, Kind.u32: return 0;
		case Kind.i64, Kind.u64: return 1;
		case Kind.f32: return 2;
		case Kind.f64: return 3;
		case Kind.pointer: return size_t.sizeof == uint.sizeof ? 0 : 1;
	}
}

// Which entry of `returnTypes` returns `kind`.
private int returnClass(Kind kind) {
	final switch (kind) {
		case Kind.void_: return 0;
		case Kind.i32: return 1;
		case Kind.u32: return 2;
		case Kind.i64, Kind.u64: return 3;
		case Kind.f32: return 4;
		case Kind.f64: return 5;
		case Kind.pointer: return size_t.sizeof == uint.sizeof ? 2 : 3;
	}
}

// Where the trampolines taking `arguments` arguments start in the table: every shorter signature comes first.
private size_t blockStart(size_t arguments) {
	size_t start = 0, signatures = returnTypes.length;
	foreach (_; 0 .. arguments) {
		start += signatures;
		signatures *= argumentTypes.length;
	}
	return start;
}

private void trampoline(R, A...)(const(void)* func, const(ulong)* arguments, ulong* result) {
	alias Function = extern(C) R function(A) @nogc nothrow;
	A values;
	static foreach (i, T; A)
		values[i] = *cast(const(T)*) &arguments[i];

	static if (is(R == void))
		(cast(Function) func)(values);
	else static if (is(R == float) || is(R == double)) {
		*result = 0;
		*cast(R*) result = (cast(Function) func)(values);
	} else static if (is(R == int))
		*result = cast(long) (cast(Function) func)(values);
	else
		*result = (cast(Function) func)(values);
}

// The table's initializer as D source: within a block, the return class is the most significant digit and the last argument the least.
private string tableSource() {
	string source = "[";
	foreach (arguments; 0 .. mizu.config.maximumTrampolineArguments + 1) {
		size_t combinations = 1;
		foreach (_; 0 .. arguments) combinations *= argumentTypes.length;
		foreach (returned; returnTypes) foreach (code; 0 .. combinations) {
			source ~= "&trampoline!(" ~ returned;
			size_t place = combinations;
			foreach (_; 0 .. arguments) {
				place /= argumentTypes.length;
				source ~= ", " ~ argumentTypes[code / place % argumentTypes.length];
			}
			source ~= "),";
		}
	}
	return source ~ "]";
}

private immutable Trampoline[blockStart(mizu.config.maximumTrampolineArguments + 1)] trampolines = mixin(tableSource());

/**
* Finds the trampoline for a function returning `kinds[0]` and taking the rest, which must not be empty.
*
* Returns: the trampoline, or null when an argument is `void` or there are more than `mizu.config.maximumTrampolineArguments` of them.
*
* Examples:
* ---
* static extern(C) int negate(int x) @nogc nothrow { return -x; }
* static immutable Kind[2] signature = [Kind.i32, Kind.i32];
* auto trampoline = find(signature[]);
* ulong[1] arguments = [5];
* ulong result;
* trampoline(&negate, arguments.ptr, &result);
* assert(cast(long) result == -5);
* static immutable Kind[2] voidArgument = [Kind.i32, Kind.void_];
* assert(find(voidArgument[]) is null);
* ---
*/
Trampoline find(scope const(Kind)[] kinds) {
	assert(kinds.length > 0, "mizu: a signature needs at least its return type");
	immutable arguments = kinds.length - 1;
	if (arguments > mizu.config.maximumTrampolineArguments) return null;

	size_t code = returnClass(kinds[0]);
	foreach (kind; kinds[1 .. $]) {
		immutable class_ = argumentClass(kind);
		if (class_ < 0) return null;
		code = code * argumentTypes.length + class_;
	}
	return trampolines[blockStart(arguments) + code];
}
