/**
* The portable program format: a serialized program, a null opcode acting as
* a terminator, and then the bytes that should sit at the bottom of the
* program's stack — everything a runner needs to execute a program it knows
* nothing else about.
*
* Note:
*   Where the C++ original measured the terminator and the scan stride in
*   `sizeof(opcode)` (the host-sized struct) while writing the body in
*   `sizeof(serialization_opcode)`, this port uses
*   `SerializationOpcode.sizeof` throughout, so the stride matches the data
*   actually in the stream and a blob written by a 64 bit host really does
*   load on a 32 bit one.
*
*   `generateSourceFile` also names instructions in full —
*   `mizu.instructions.core.add` rather than `add` — where the C++ original
*   emitted bare names into a header that had already included everything.
*   See `mizu.lookup`.
*/
module mizu.portable_format;

import core.stdc.stdio : snprintf;
import core.stdc.string : memcpy, strlen;

import fp.dynarray : dynFree = free, grow, growToSize;
import fp.pointer : ptrLength = length;
import fp.string : appendChar = append, concatenateSlice;

import mizu.lookup;
import mizu.opcode;
import mizu.serialize;

@nogc nothrow:

/// A program and the environment it should start executing in.
struct PortableProgram {
	/// A libfp dynarray of opcodes; free it with `fp.dynarray.free`.
	Opcode* program;
	/// The environment, with `data` already copied to the bottom of its stack.
	RegistersAndStack environment;
}

/**
* Converts a Mizu `program` and some `data` into a portable program that can
* be executed anywhere.
*
* Params:
*   L = the lookup that assigns the instruction IDs; pass your own
*     `mizu.lookup.Lookup` instantiation for a program that uses
*     instructions of your own
*   program = the program to serialize
*   data = bytes to place at the bottom of the program's stack
* Returns:
*   A libfp dynarray of bytes; free it with `fp.dynarray.free`.
*/
ubyte* toPortable(alias L = defaultLookup)(const(Opcode)[] program, const(void)[] data = null) @trusted {
	assert(data.length <= memorySizeBytes);

	auto result = toBinary!L(program);
	if (data.length == 0) return result;

	// Make sure there is a null opcode marking the end of the program.
	auto last = &program[$ - 1];
	if (last.op !is null || last.out_ != 0 || last.a != 0 || last.b != 0) {
		immutable end = ptrLength(result);
		grow(result, SerializationOpcode.sizeof);
		SerializationOpcode marker;
		memcpy(result + end, &marker, SerializationOpcode.sizeof);
	}

	// Paste in the stack data.
	immutable end = ptrLength(result);
	grow(result, data.length);
	memcpy(result + end, data.ptr, data.length);
	return result;
}

/**
* Converts a Mizu `program` and an `env` into a snapshot of a portable
* program that can be executed anywhere.
*
* Params:
*   L = ditto `toPortable`
*   program = the program to snapshot
*   env = the environment to snapshot
* Returns:
*   A libfp dynarray of bytes; free it with `fp.dynarray.free`.
*/
ubyte* toPortable(alias L = defaultLookup)(const(Opcode)[] program, ref RegistersAndStack env) @trusted {
	return toPortable!L(program, (cast(const(ubyte)*) env.memory.ptr)[0 .. memorySizeBytes]);
}

/**
* Converts a blob of portable `binary` data back into a Mizu program and its
* environment.
*
* Note:
*   The returned environment still needs `setupEnvironment` before it can run.
*
* Params:
*   L = the lookup that resolves the instruction IDs; pass the same one
*     `toPortable` used
*   binary = the bytes to deserialize
*/
PortableProgram fromPortable(alias L = defaultLookup)(const(void)[] binary) @trusted {
	auto opcodes = cast(const(SerializationOpcode)*) binary.ptr;
	size_t count = 0;

	// While there are opcodes left in the data...
	while (binary.length >= SerializationOpcode.sizeof) {
		auto op = &opcodes[count];
		++count;
		binary = binary[SerializationOpcode.sizeof .. $];

		// An all-zero opcode marks the end of the program.
		if (op.op == 0 && op.out_ == 0 && op.a == 0 && op.b == 0)
			break;
	}

	PortableProgram result;
	result.program = fromBinary!L((cast(const(void)*) opcodes)[0 .. count * SerializationOpcode.sizeof]);
	if (binary.length == 0) return result;

	fillStackBottom(result.environment, binary);
	return result;
}

/**
* Generates a self-contained D source file that runs the provided `program`
* in the provided `env`.
*
* The C++ original emitted a C++ header; this emits D, since that is what a
* D port can actually compile.
*
* Because `mizu.lookup` stores fully qualified instruction names, the
* generated file names every instruction by its module and imports exactly
* the modules the program draws on — whether they are Mizu's own or an
* extension's. Nothing has to be told where an instruction lives; anything
* else the file needs can still go in `extraImports`.
*
* Params:
*   L = the lookup that names the instructions; pass your own
*     `mizu.lookup.Lookup` instantiation for a program that uses
*     instructions of your own
*   program = the program to generate source for
*   env = the environment the program should begin executing in
*   extraImports = extra `import` lines (one per line, including the `import`
*     keyword and the semicolon), written after the ones derived from the
*     instruction names. The instruction modules are no longer among the
*     things that have to be named here; this is for whatever else a
*     particular build needs — a package that has to be imported for its
*     `static this`, say, or a module the extra instructions expect to have
*     been linked in.
* Returns:
*   A libfp string; free it with `fp.string.free`.
*/
char* generateSourceFile(alias L = defaultLookup)(const(Opcode)[] program, ref RegistersAndStack env, scope const(char)[] extraImports = null) @trusted {
	char* out_ = null;
	char[64] scratch;

	void put(scope const(char)[] text) { concatenateSlice(out_, text); }
	void putUnsigned(ulong value, scope const(char)* format = "%llu") {
		immutable n = snprintf(scratch.ptr, scratch.length, format, value);
		put(scratch[0 .. n]);
	}

	// Which instructions the program uses, so the file can import their
	// modules and nothing else.
	bool[L.entryCount] used;
	foreach (ref code; program) {
		immutable id = L.lookupId(code.op);
		assert(L.validId(id), "Program contains an instruction the lookup does not know.");
		used[id] = true;
	}

	put("import mizu;\n"); // The VM itself: `Opcode`, `setupEnvironment`, and so on.
	// A module's instructions are contiguous in the table, so remembering the
	// last one emitted is enough to import each module once.
	const(char)[] lastModule;
	foreach (id; 0 .. L.entryCount) {
		if (!used[id]) continue;
		auto mod = moduleOfName(L.lookupName(id));
		if (mod.length == 0 || sameName(mod, lastModule)) continue;
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
		// Every instruction is named in full; `programEnd` is a null constant
		// rather than a function, so it is the one row without an `&`.
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

	for (size_t i = 0; i < memorySize;) {
		put("\t\t");
		for (size_t j = 0; j < 12 && i < memorySize; ++j, ++i) {
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
		~ "\tmizu.startFromEnvironment(program[], environment);\n"
		~ "\treturn 0;\n"
		~ "}\n");

	return out_;
}

unittest {
	import mizu.instructions.core;
	import fp.string : stringFree = free;

	static immutable Opcode[3] program = [
		Opcode(&loadImmediate, registers.t(0)).setImmediate(40),
		Opcode(&debugPrint, 0, registers.t(0)),
		Opcode(&halt),
	];

	// Round trip with no stack data: just the serialized program.
	auto bare = toPortable(program[]);
	scope(exit) dynFree(bare);
	assert(ptrLength(bare) == 3 * SerializationOpcode.sizeof);

	auto restored = fromPortable(bare[0 .. ptrLength(bare)]);
	scope(exit) dynFree(restored.program);
	assert(ptrLength(restored.program) == 3);
	assert(restored.program[0].op is &loadImmediate);
	assert(restored.program[0].immediate == 40);
	assert(restored.program[2].op is &halt);
}

unittest {
	import mizu.instructions.core;

	static immutable Opcode[2] program = [
		Opcode(&loadImmediate, registers.t(0)).setImmediate(7),
		Opcode(&halt),
	];
	static immutable ubyte[4] data = [1, 2, 3, 4];

	// With stack data, a terminator gets inserted between program and data.
	auto blob = toPortable(program[], data[]);
	scope(exit) dynFree(blob);
	assert(ptrLength(blob) == 3 * SerializationOpcode.sizeof + data.length);

	auto restored = fromPortable(blob[0 .. ptrLength(blob)]);
	scope(exit) dynFree(restored.program);

	// The terminator is kept, so the program ends in a null op.
	assert(ptrLength(restored.program) == 3);
	assert(restored.program[2].op is null);

	// And the data landed at the bottom of the stack.
	auto bottom = (cast(const(ubyte)*) restored.environment.memory.ptr) + memorySizeBytes - data.length;
	foreach (i; 0 .. data.length)
		assert(bottom[i] == data[i]);
}

unittest {
	import mizu.instructions.core;
	import fp.string : stringFree = free, findSlices = findSlices;

	static immutable Opcode[2] program = [
		Opcode(&loadImmediate, registers.t(0)).setImmediate(40),
		Opcode(&halt),
	];

	RegistersAndStack env;
	setupEnvironment(env, program[]);
	env.memory[3] = 0xABC;

	auto source = generateSourceFile(program[], env);
	scope(exit) stringFree(source);

	import fp.string : stringLength = length, sliceOf = slice;
	auto text = sliceOf(source);
	assert(text.length > 0);
	// Both instructions are named in full, under the module that declares
	// them, and that module is imported. The register value is there too.
	assert(findSlices(text, "import mizu;\n", 0) != size_t.max);
	assert(findSlices(text, "import mizu.instructions.core;\n", 0) != size_t.max);
	assert(findSlices(text, "&mizu.instructions.core.loadImmediate", 0) != size_t.max);
	assert(findSlices(text, "&mizu.instructions.core.halt", 0) != size_t.max);
	assert(findSlices(text, "0xABC", 0) != size_t.max);
	assert(findSlices(text, "extern(C) int main()", 0) != size_t.max);

	// Only the modules the program actually draws on are imported.
	assert(findSlices(text, "import mizu.instructions.f32;", 0) == size_t.max);
	assert(findSlices(text, "import mizu.ffi.instructions;", 0) == size_t.max);
}

version (unittest) private extern(C) void* testPortableInstruction(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	return null;
}

unittest {
	// An instruction from another package needs no help from the caller: the
	// lookup knows the module it lives in, so the generated file imports it.
	import mizu.instructions.core;
	import fp.string : stringFree = free, findSlices, sliceOf = slice;

	alias extended = Lookup!(mizu.portable_format);

	static immutable Opcode[3] program = [
		Opcode(&loadImmediate, registers.t(0)).setImmediate(1),
		Opcode(&testPortableInstruction, registers.t(1), registers.t(0)),
		Opcode(null), // A programEnd terminator, the one row that is not a function.
	];

	RegistersAndStack env;
	setupEnvironment(env, program[]);

	// Whatever the caller adds is written after the derived imports.
	auto source = generateSourceFile!extended(program[], env, "import core.stdc.stdio;\n");
	scope(exit) stringFree(source);
	auto text = sliceOf(source);

	immutable derived = findSlices(text, "import mizu.portable_format;\n", 0);
	immutable extra = findSlices(text, "import core.stdc.stdio;\n", 0);
	assert(extra != size_t.max);
	assert(derived < extra);
	assert(extra < findSlices(text, "static immutable mizu.Opcode[", 0));

	assert(findSlices(text, "import mizu.portable_format;\n", 0) != size_t.max);
	assert(findSlices(text, "&mizu.portable_format.testPortableInstruction", 0) != size_t.max);
	assert(findSlices(text, "import mizu.instructions.core;\n", 0) != size_t.max);
	assert(findSlices(text, "mizu.Opcode(mizu.instructions.core.programEnd, 0, 0, 0)", 0) != size_t.max);
	// ... and `programEnd` is named rather than having its address taken.
	assert(findSlices(text, "&mizu.instructions.core.programEnd", 0) == size_t.max);
}

unittest {
	// The environment-snapshotting overload of `toPortable`: the whole memory
	// space becomes the stack data, so a register value survives the round trip.
	import mizu.instructions.core;

	static immutable Opcode[2] program = [
		Opcode(&loadImmediate, registers.t(0)).setImmediate(5),
		Opcode(&halt),
	];

	RegistersAndStack env;
	setupEnvironment(env, program[]);
	env.memory[7] = 0xFEEDFACE;

	auto blob = toPortable(program[], env);
	scope(exit) dynFree(blob);
	// Program, the inserted terminator, then a full copy of the memory space.
	assert(ptrLength(blob) == 3 * SerializationOpcode.sizeof + memorySizeBytes);

	auto restored = fromPortable(blob[0 .. ptrLength(blob)]);
	scope(exit) dynFree(restored.program);
	assert(restored.environment.memory[7] == 0xFEEDFACE);
}
