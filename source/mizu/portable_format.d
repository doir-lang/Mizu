/**
* The portable program format: a serialized program, a null opcode acting as a terminator, and then the bytes that should sit at the bottom of the program's stack; everything a runner needs to execute a program it knows nothing else about.
*
* Note: the terminator and the scan stride are measured in `SerializationOpcode.sizeof` throughout, matching the data actually in the stream, so a blob written by a 64 bit host loads on a 32 bit one. The C++ original measured them in the host-sized `sizeof(opcode)`.
*
* `generateSourceFile` names instructions in full, `mizu.instructions.core.add` rather than `add`; see `mizu.lookup`.
*/
module mizu.portable_format;

import core.stdc.stdio : snprintf;
import core.stdc.string : memcpy;

static import fp.dynarray;
static import fp.pointer;
static import fp.string;

static import mizu.lookup;
static import mizu.opcode;
static import mizu.serialize;

version(unittest) static import mizu.instructions.core;

@nogc nothrow:

/// A program and the environment it should start executing in.
struct PortableProgram {
	/// A libfp dynarray of opcodes; free it with `fp.dynarray.free`.
	mizu.opcode.Opcode* program;
	/// The environment, with `data` already copied to the bottom of its stack.
	mizu.opcode.RegistersAndStack environment;
}

/**
* Converts a Mizu `program` and some `data` into a portable program that can be executed anywhere.
*
* Params:
*   L = the lookup that assigns the instruction IDs; pass your own `mizu.lookup.Lookup` instantiation for a program that uses instructions of your own
*   program = the program to serialize
*   data = bytes to place at the bottom of the program's stack, at most `memorySizeBytes` long
* Returns: a libfp dynarray of bytes, to free with `fp.dynarray.free`; null if allocation fails.
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* static immutable ubyte[2] data = [1, 2];
* ubyte* blob = toPortable(program[], data[]);
* scope(exit) fp.dynarray.free(blob);
* assert(fp.pointer.length(blob) == 2 * SerializationOpcode.sizeof + data.length);
* ---
*/
ubyte* toPortable(alias L = mizu.lookup.defaultLookup)(const(mizu.opcode.Opcode)[] program, const(void)[] data = null) @trusted {
	assert(data.length <= mizu.opcode.memorySizeBytes, "mizu: data does not fit in memory");

	auto result = mizu.serialize.toBinary!L(program);
	if (data.length == 0) return result;

	// Make sure a null opcode marks the end of the program.
	immutable terminated = program.length > 0 && program[$ - 1] == mizu.opcode.Opcode.init;
	immutable marker = terminated ? 0 : mizu.serialize.SerializationOpcode.sizeof;
	immutable end = fp.pointer.length(result);
	if (fp.dynarray.grow(result, marker + data.length) is null) {
		fp.dynarray.free(result);
		return null;
	}
	mizu.serialize.SerializationOpcode terminator;
	memcpy(result + end, &terminator, marker);
	memcpy(result + end + marker, data.ptr, data.length);
	return result;
}

/**
* Converts a Mizu `program` and an `env` into a snapshot of a portable program that can be executed anywhere; the whole of `env.memory`, registers included, becomes the stack data.
*
* Params:
*   L = ditto `toPortable`
*   program = the program to snapshot
*   env = the environment to snapshot
* Returns: a libfp dynarray of bytes, to free with `fp.dynarray.free`; null if allocation fails.
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* ubyte* blob = toPortable(program[], env);
* scope(exit) fp.dynarray.free(blob);
* assert(fp.pointer.length(blob) == 2 * SerializationOpcode.sizeof + memorySizeBytes);
* ---
*/
ubyte* toPortable(alias L = mizu.lookup.defaultLookup)(const(mizu.opcode.Opcode)[] program, ref mizu.opcode.RegistersAndStack env) @trusted {
	return toPortable!L(program, (cast(const(ubyte)*) env.memory.ptr)[0 .. mizu.opcode.memorySizeBytes]);
}

/**
* Converts a blob of portable `binary` data back into a Mizu program and its environment.
*
* Note: the returned environment still needs `setupEnvironment` before it can run.
*
* Params:
*   L = the lookup that resolves the instruction IDs; pass the same one `toPortable` used
*   binary = the bytes to deserialize
* Returns: the program and its environment; the program is null if allocation fails.
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* static immutable ubyte[2] data = [1, 2];
* ubyte* blob = toPortable(program[], data[]);
* scope(exit) fp.dynarray.free(blob);
* PortableProgram restored = fromPortable(blob[0 .. fp.pointer.length(blob)]);
* scope(exit) fp.dynarray.free(restored.program);
* assert(restored.program[0].op is &halt);
* assert(restored.program[1].op is null);
* ---
*/
PortableProgram fromPortable(alias L = mizu.lookup.defaultLookup)(const(void)[] binary) @trusted {
	auto opcodes = cast(const(mizu.serialize.SerializationOpcode)*) binary.ptr;
	size_t count = 0;

	while (binary.length >= mizu.serialize.SerializationOpcode.sizeof) {
		auto op = &opcodes[count];
		++count;
		binary = binary[mizu.serialize.SerializationOpcode.sizeof .. $];

		// An all-zero opcode marks the end of the program.
		if (*op == mizu.serialize.SerializationOpcode.init)
			break;
	}

	PortableProgram result;
	result.program = mizu.serialize.fromBinary!L((cast(const(void)*) opcodes)[0 .. count * mizu.serialize.SerializationOpcode.sizeof]);
	if (binary.length == 0) return result;

	mizu.opcode.fillStackBottom(result.environment, binary);
	return result;
}

/**
* Generates a self-contained D source file that runs the provided `program` in the provided `env`.
*
* Because `mizu.lookup` stores fully qualified instruction names, the generated file names every instruction by its module and imports exactly the modules the program draws on, whether they are Mizu's own or an extension's; anything else the file needs can go in `extraImports`.
*
* Params:
*   L = the lookup that names the instructions; pass your own `mizu.lookup.Lookup` instantiation for a program that uses instructions of your own
*   program = the program to generate source for, every instruction of which `L` must know
*   env = the environment the program should begin executing in
*   extraImports = extra `import` lines (one per line, including the `import` keyword and the semicolon), written after the ones derived from the instruction names; for whatever else a particular build needs, such as a module the extra instructions expect to have been linked in
* Returns: a libfp string, to free with `fp.string.free`; null if allocation fails.
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* char* source = generateSourceFile(program[], env);
* scope(exit) fp.string.free(source);
* assert(fp.string.contains(source, "&mizu.instructions.core.halt", 0));
* ---
*/
char* generateSourceFile(alias L = mizu.lookup.defaultLookup)(const(mizu.opcode.Opcode)[] program, ref mizu.opcode.RegistersAndStack env, scope const(char)[] extraImports = null) @trusted {
	char* out_ = null;
	bool failed = false;
	char[64] scratch;

	void put(scope const(char)[] text) {
		if (!failed && fp.string.concatenate(out_, text) is null) failed = true;
	}
	void putUnsigned(ulong value, scope const(char)* format = "%llu") {
		immutable n = snprintf(scratch.ptr, scratch.length, format, value);
		put(scratch[0 .. n]);
	}

	// Which instructions the program uses, so the file imports their modules and nothing else.
	bool[L.entryCount] used;
	foreach (ref code; program) {
		immutable id = L.lookupId(code.op);
		assert(L.validId(id), "Program contains an instruction the lookup does not know.");
		used[id] = true;
	}

	put("import mizu;\n");
	// A module's instructions are contiguous in the table, so remembering the last one emitted imports each module once.
	const(char)[] lastModule;
	foreach (id; 0 .. L.entryCount) {
		if (!used[id]) continue;
		auto mod = mizu.lookup.moduleOfName(L.lookupName(id));
		if (mod.length == 0 || mizu.lookup.sameName(mod, lastModule)) continue;
		put("import ");
		put(mod);
		put(";\n");
		lastModule = mod;
	}
	if (extraImports.length) put(extraImports);

	put("\nstatic immutable mizu.Opcode[");
	putUnsigned(program.length);
	put("] program = [\n");

	foreach (ref code; program) {
		immutable id = L.lookupId(code.op);
		put("\tmizu.Opcode(");
		// `programEnd` is a null constant rather than a function, so it is the one row without an `&`.
		if (id != 0) put("&");
		put(L.lookupName(id));
		put(", ");
		putUnsigned(code.out_);
		put(", ");
		putUnsigned(code.a);
		put(", ");
		putUnsigned(code.b);
		put("),\n");
	}

	put("];\n\nextern(C) int main() {\n"
		~ "\tmizu.RegistersAndStack environment;\n"
		~ "\tstatic immutable ulong[mizu.memorySize] memory = [\n");

	for (size_t i = 0; i < mizu.opcode.memorySize;) {
		put("\t\t");
		for (size_t j = 0; j < 12 && i < mizu.opcode.memorySize; ++j, ++i) {
			put("0x");
			putUnsigned(env.memory[i], "%llX");
			put(", ");
		}
		put("\n");
	}

	put("\t];\n"
		~ "\tenvironment.memory.ptr[0 .. mizu.memorySize] = memory[];\n"
		~ "\tmizu.setupEnvironment(environment, program[]);\n"
		~ "\n"
		~ "\tcast(void) mizu.startFromEnvironment(program[], environment);\n"
		~ "\treturn 0;\n"
		~ "}\n");

	if (failed) fp.string.free(out_);
	return out_;
}

unittest {
	static immutable mizu.opcode.Opcode[3] program = [
		mizu.opcode.setImmediate(mizu.opcode.Opcode(&mizu.instructions.core.loadImmediate, mizu.opcode.Registers.t(0)), 40),
		mizu.opcode.Opcode(&mizu.instructions.core.debugPrint, 0, mizu.opcode.Registers.t(0)),
		mizu.opcode.Opcode(&mizu.instructions.core.halt),
	];

	// Round trip with no stack data: just the serialized program.
	auto bare = toPortable(program[]);
	scope(exit) fp.dynarray.free(bare);
	assert(fp.pointer.length(bare) == 3 * mizu.serialize.SerializationOpcode.sizeof);

	auto restored = fromPortable(bare[0 .. fp.pointer.length(bare)]);
	scope(exit) fp.dynarray.free(restored.program);
	assert(fp.pointer.length(restored.program) == 3);
	assert(restored.program[0].op is &mizu.instructions.core.loadImmediate);
	assert(mizu.opcode.immediate(restored.program[0]) == 40);
	assert(restored.program[2].op is &mizu.instructions.core.halt);
}

unittest {
	static immutable mizu.opcode.Opcode[2] program = [
		mizu.opcode.setImmediate(mizu.opcode.Opcode(&mizu.instructions.core.loadImmediate, mizu.opcode.Registers.t(0)), 7),
		mizu.opcode.Opcode(&mizu.instructions.core.halt),
	];
	static immutable ubyte[4] data = [1, 2, 3, 4];

	// With stack data, a terminator gets inserted between program and data.
	auto blob = toPortable(program[], data[]);
	scope(exit) fp.dynarray.free(blob);
	assert(fp.pointer.length(blob) == 3 * mizu.serialize.SerializationOpcode.sizeof + data.length);

	auto restored = fromPortable(blob[0 .. fp.pointer.length(blob)]);
	scope(exit) fp.dynarray.free(restored.program);

	// The terminator is kept, so the program ends in a null op.
	assert(fp.pointer.length(restored.program) == 3);
	assert(restored.program[2].op is null);

	// And the data landed at the bottom of the stack.
	auto bottom = (cast(const(ubyte)*) restored.environment.memory.ptr) + mizu.opcode.memorySizeBytes - data.length;
	foreach (i; 0 .. data.length)
		assert(bottom[i] == data[i]);

	// A program already ending in a terminator gets no second one.
	static immutable mizu.opcode.Opcode[2] terminated = [mizu.opcode.Opcode(&mizu.instructions.core.halt), mizu.opcode.Opcode.init];
	auto once = toPortable(terminated[], data[]);
	scope(exit) fp.dynarray.free(once);
	assert(fp.pointer.length(once) == 2 * mizu.serialize.SerializationOpcode.sizeof + data.length);

	// An empty program still gets its terminator, rather than indexing past the end looking for one.
	auto empty = toPortable(program[0 .. 0], data[]);
	scope(exit) fp.dynarray.free(empty);
	assert(fp.pointer.length(empty) == mizu.serialize.SerializationOpcode.sizeof + data.length);
}

unittest {
	static immutable mizu.opcode.Opcode[2] program = [
		mizu.opcode.setImmediate(mizu.opcode.Opcode(&mizu.instructions.core.loadImmediate, mizu.opcode.Registers.t(0)), 40),
		mizu.opcode.Opcode(&mizu.instructions.core.halt),
	];

	mizu.opcode.RegistersAndStack env;
	mizu.opcode.setupEnvironment(env, program[]);
	env.memory[3] = 0xABC;

	auto source = generateSourceFile(program[], env);
	scope(exit) fp.string.free(source);
	assert(source !is null);

	// Both instructions are named in full, under their declaring module, which is imported; the register value is there too.
	assert(fp.string.contains(source, "import mizu;\n", 0));
	assert(fp.string.contains(source, "import mizu.instructions.core;\n", 0));
	assert(fp.string.contains(source, "&mizu.instructions.core.loadImmediate", 0));
	assert(fp.string.contains(source, "&mizu.instructions.core.halt", 0));
	assert(fp.string.contains(source, "0xABC", 0));
	assert(fp.string.contains(source, "extern(C) int main()", 0));

	// Only the modules the program actually draws on are imported.
	assert(!fp.string.contains(source, "import mizu.instructions.f32;", 0));
	assert(!fp.string.contains(source, "import mizu.ffi.instructions;", 0));
}

version (unittest) private extern(C) void* testPortableInstruction(mizu.opcode.Opcode* pc, ulong* registers, mizu.opcode.RegistersAndStack* env, ubyte* sp) {
	return null;
}

unittest {
	// The lookup knows the module an extension's instruction lives in, so the generated file imports it unasked.
	alias extended = mizu.lookup.Lookup!(mizu.portable_format);

	static immutable mizu.opcode.Opcode[3] program = [
		mizu.opcode.setImmediate(mizu.opcode.Opcode(&mizu.instructions.core.loadImmediate, mizu.opcode.Registers.t(0)), 1),
		mizu.opcode.Opcode(&testPortableInstruction, mizu.opcode.Registers.t(1), mizu.opcode.Registers.t(0)),
		mizu.opcode.Opcode(null), // A programEnd terminator, the one row that is not a function.
	];

	mizu.opcode.RegistersAndStack env;
	mizu.opcode.setupEnvironment(env, program[]);

	// Whatever the caller adds is written after the derived imports.
	auto source = generateSourceFile!extended(program[], env, "import core.stdc.stdio;\n");
	scope(exit) fp.string.free(source);

	immutable derived = fp.string.find(source, "import mizu.portable_format;\n", 0);
	immutable extra = fp.string.find(source, "import core.stdc.stdio;\n", 0);
	assert(derived != fp.pointer.notFound);
	assert(extra != fp.pointer.notFound);
	assert(derived < extra);
	assert(extra < fp.string.find(source, "static immutable mizu.Opcode[", 0));

	assert(fp.string.contains(source, "&mizu.portable_format.testPortableInstruction", 0));
	assert(fp.string.contains(source, "import mizu.instructions.core;\n", 0));
	assert(fp.string.contains(source, "mizu.Opcode(mizu.instructions.core.programEnd, 0, 0, 0)", 0));
	// ... and `programEnd` is named rather than having its address taken.
	assert(!fp.string.contains(source, "&mizu.instructions.core.programEnd", 0));
}

unittest {
	// Snapshotting an environment makes the whole memory space the stack data, so a register value survives the round trip.
	static immutable mizu.opcode.Opcode[2] program = [
		mizu.opcode.setImmediate(mizu.opcode.Opcode(&mizu.instructions.core.loadImmediate, mizu.opcode.Registers.t(0)), 5),
		mizu.opcode.Opcode(&mizu.instructions.core.halt),
	];

	mizu.opcode.RegistersAndStack env;
	mizu.opcode.setupEnvironment(env, program[]);
	env.memory[7] = 0xFEEDFACE;

	auto blob = toPortable(program[], env);
	scope(exit) fp.dynarray.free(blob);
	// Program, the inserted terminator, then a full copy of the memory space.
	assert(fp.pointer.length(blob) == 3 * mizu.serialize.SerializationOpcode.sizeof + mizu.opcode.memorySizeBytes);

	auto restored = fromPortable(blob[0 .. fp.pointer.length(blob)]);
	scope(exit) fp.dynarray.free(restored.program);
	assert(restored.environment.memory[7] == 0xFEEDFACE);
}
