/**
* Converts Mizu programs to and from a flat byte blob, replacing the host function pointer in each opcode with its `mizu.lookup` ID so the result does not depend on where the instructions happen to be loaded.
*
* Note: the blob stores little-endian integers in fixed widths (see `SerializationOpcode`, which pins the op field at 64 bits), so 32 and 64 bit hosts of either endianness interoperate.
*/
module mizu.serialize;

static import core.bitop;

static import fp.dynarray;
static import fp.pointer;

static import mizu.lookup;
static import mizu.opcode;

version(unittest) static import mizu.instructions.core;

@nogc nothrow:

/// A fixed-size version of `mizu.opcode.Opcode`, for serialization.
struct SerializationOpcode {
	/// The instruction's `mizu.lookup` ID, always 64 bits wide.
	ulong op;
	/// Ditto `Opcode.out_`
	mizu.opcode.Reg out_;
	/// Ditto `Opcode.a`
	mizu.opcode.Reg a;
	/// Ditto `Opcode.b`
	mizu.opcode.Reg b;
}

/**
* Widens a runtime `Opcode`, keeping its op as a raw pointer value; ID substitution happens separately.
*
* Examples:
* ---
* static immutable Opcode code = Opcode(&halt, 1, 2, 3);
* auto wide = fromOpcode(code);
* assert(wide.op == cast(size_t) &halt && wide.out_ == 1 && wide.a == 2 && wide.b == 3);
* ---
*/
SerializationOpcode fromOpcode(const mizu.opcode.Opcode code) {
	return SerializationOpcode(cast(size_t) code.op, code.out_, code.a, code.b);
}

/**
* Narrows a `SerializationOpcode` whose op holds a raw pointer value back to a runtime `Opcode`.
*
* Examples:
* ---
* static immutable Opcode code = Opcode(&halt, 1, 2, 3);
* assert(toOpcode(fromOpcode(code)) == code);
* ---
*/
mizu.opcode.Opcode toOpcode(const SerializationOpcode code) {
	return mizu.opcode.Opcode(cast(mizu.opcode.Instruction) cast(size_t) code.op, code.out_, code.a, code.b);
}

/**
* Flips the byte order of every field of `code`.
*
* Examples:
* ---
* auto code = SerializationOpcode(1, 2, 3, 4);
* byteswap(code);
* assert(code.op == 1UL << 56 && code.out_ == 0x200);
* ---
*/
void byteswap(ref SerializationOpcode code) {
	code.op = core.bitop.bswap(code.op);
	code.out_ = core.bitop.byteswap(code.out_);
	code.a = core.bitop.byteswap(code.a);
	code.b = core.bitop.byteswap(code.b);
}

/**
* Converts a Mizu `program` into a byte array ready to be written to a file or sent over the network.
*
* Params:
*   L = the lookup that assigns the IDs; pass your own `mizu.lookup.Lookup` instantiation to serialize a program that uses instructions of your own
*   program = the program to serialize
* Returns: a libfp dynarray of bytes, to free with `fp.dynarray.free`; null if allocation fails.
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* ubyte* binary = toBinary(program[]);
* scope(exit) fp.dynarray.free(binary);
* assert(fp.pointer.length(binary) == SerializationOpcode.sizeof);
* ---
*/
ubyte* toBinary(alias L = mizu.lookup.defaultLookup)(const(mizu.opcode.Opcode)[] program) @trusted {
	ubyte* result = null;
	if (fp.dynarray.growToSize(result, program.length * SerializationOpcode.sizeof) is null) return null;

	auto ops = cast(SerializationOpcode*) result;
	foreach (i, ref code; program) {
		ops[i] = fromOpcode(code);
		ops[i].op = L.lookupId(code.op);
		version(BigEndian) byteswap(ops[i]);
	}
	return result;
}

/**
* Converts a blob of `binary` data, a whole number of `SerializationOpcode`s long, back into a Mizu program.
*
* Params:
*   L = the lookup that resolves the IDs; pass the same one `toBinary` used
*   binary = the bytes to deserialize
* Returns: a libfp dynarray of opcodes, to free with `fp.dynarray.free`; null if allocation fails. An unknown ID becomes a null op.
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* ubyte* binary = toBinary(program[]);
* scope(exit) fp.dynarray.free(binary);
* Opcode* restored = fromBinary(binary[0 .. fp.pointer.length(binary)]);
* scope(exit) fp.dynarray.free(restored);
* assert(restored[0].op is &halt);
* ---
*/
mizu.opcode.Opcode* fromBinary(alias L = mizu.lookup.defaultLookup)(const(void)[] binary) @trusted {
	assert(binary.length % SerializationOpcode.sizeof == 0, "mizu: binary is not a whole number of opcodes");
	immutable count = binary.length / SerializationOpcode.sizeof;

	mizu.opcode.Opcode* result = null;
	if (fp.dynarray.growToSize(result, count) is null) return null;

	auto source = cast(const(SerializationOpcode)*) binary.ptr;
	foreach (i; 0 .. count) {
		SerializationOpcode code = source[i];
		version(BigEndian) byteswap(code);
		code.op = cast(ulong) cast(size_t) L.lookupPointer(cast(mizu.lookup.Id) code.op);
		result[i] = toOpcode(code);
	}
	return result;
}

unittest {
	// `byteswap` only runs on a big endian host, so call it directly: every field flips, and flipping twice is the identity.
	auto code = SerializationOpcode(0x0123456789ABCDEF, 0x1122, 0x3344, 0x5566);

	auto swapped = code;
	byteswap(swapped);
	assert(swapped.op == 0xEFCDAB8967452301);
	assert(swapped.out_ == 0x2211);
	assert(swapped.a == 0x4433);
	assert(swapped.b == 0x6655);

	byteswap(swapped);
	assert(swapped == code);
}

unittest {
	static immutable mizu.opcode.Opcode[4] program = [
		mizu.opcode.setImmediate(mizu.opcode.Opcode(&mizu.instructions.core.loadImmediate, mizu.opcode.Registers.t(0)), 40),
		mizu.opcode.Opcode(&mizu.instructions.core.debugPrint, 0, mizu.opcode.Registers.t(0)),
		mizu.opcode.Opcode(&mizu.instructions.core.add, 3, 2, 1),
		mizu.opcode.Opcode(&mizu.instructions.core.halt),
	];

	auto binary = toBinary(program[]);
	scope(exit) fp.dynarray.free(binary);
	assert(fp.pointer.length(binary) == 4 * SerializationOpcode.sizeof);

	auto restored = fromBinary(binary[0 .. fp.pointer.length(binary)]);
	scope(exit) fp.dynarray.free(restored);
	assert(fp.pointer.length(restored) == 4);

	foreach (i; 0 .. 4)
		assert(restored[i] == program[i]);
	assert(mizu.opcode.immediate(restored[0]) == 40);

	// A null op (programEnd) survives the round trip as a null op.
	static immutable mizu.opcode.Opcode[1] terminator = [mizu.opcode.Opcode(null, 0, 0, 0)];
	auto end = toBinary(terminator[]);
	scope(exit) fp.dynarray.free(end);
	auto restoredEnd = fromBinary(end[0 .. fp.pointer.length(end)]);
	scope(exit) fp.dynarray.free(restoredEnd);
	assert(restoredEnd[0].op is null);

	// An empty program round trips as an empty array.
	auto none = toBinary(program[0 .. 0]);
	scope(exit) fp.dynarray.free(none);
	assert(none !is null && fp.pointer.length(none) == 0);
	auto restoredNone = fromBinary(none[0 .. 0]);
	scope(exit) fp.dynarray.free(restoredNone);
	assert(restoredNone !is null && fp.pointer.length(restoredNone) == 0);
}
