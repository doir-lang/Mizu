/**
* Converts Mizu programs to and from a flat byte blob, replacing the host
* function pointer in each opcode with its `mizu.lookup` ID so the result
* does not depend on where the instructions happen to be loaded.
*
* Note:
*   The blob still assumes a fixed pointer size and little-endian integers,
*   so a program serialized on one machine loads on another only if both
*   agree — see `SerializationOpcode`, which pins the op field at 64 bits so
*   at least 32 and 64 bit hosts interoperate.
*/
module mizu.serialize;

import core.stdc.string : memcpy;

import fp.dynarray : dynGrowToSize = growToSize, dynFree = free, pushBack, reserve;
import fp.pointer : ptrLength = length;

import mizu.lookup;
import mizu.opcode;

@nogc nothrow:

/// A fixed-size version of `Opcode`, for serialization.
struct SerializationOpcode {
@nogc nothrow:
	/// The instruction's `mizu.lookup` ID, always 64 bits wide.
	ulong op;
	/// Ditto `Opcode.out_`
	Reg out_;
	/// Ditto `Opcode.a`
	Reg a;
	/// Ditto `Opcode.b`
	Reg b;

	/// Widens a runtime `Opcode` (ID substitution happens separately).
	static SerializationOpcode fromOpcode(ref const Opcode code) {
		SerializationOpcode result;
		result.op = cast(size_t) code.op;
		result.out_ = code.out_;
		result.a = code.a;
		result.b = code.b;
		return result;
	}

	/// Narrows back to a runtime `Opcode`.
	Opcode toOpcode() const {
		Opcode result;
		result.op = cast(Instruction) cast(size_t) op;
		result.out_ = out_;
		result.a = a;
		result.b = b;
		return result;
	}

	/// Flips every field's byte order.
	void byteswap() {
		import core.bitop : bswap, byteswap;
		op = bswap(op);
		out_ = byteswap(out_);
		a = byteswap(a);
		b = byteswap(b);
	}
}

/**
* Converts a Mizu `program` into a byte array ready to be written to a file
* or sent over the network.
*
* Params:
*   L = the lookup that assigns the IDs; pass your own
*     `mizu.lookup.Lookup` instantiation to serialize a program that uses
*     instructions of your own
*   program = the program to serialize
* Returns:
*   A libfp dynarray of bytes; free it with `fp.dynarray.free`.
*/
ubyte* toBinary(alias L = defaultLookup)(const(Opcode)[] program) @trusted {
	ubyte* result = null;
	dynGrowToSize(result, program.length * SerializationOpcode.sizeof);

	auto ops = cast(SerializationOpcode*) result;
	foreach (i, ref code; program) {
		ops[i] = SerializationOpcode.fromOpcode(code);
		// Replace the host op pointer with its lookup ID.
		ops[i].op = L.lookupId(code.op);
		version(BigEndian) ops[i].byteswap();
	}
	return result;
}

/**
* Converts a blob of `binary` data back into a Mizu program.
*
* Params:
*   L = the lookup that resolves the IDs; pass the same one `toBinary` used
*   binary = the bytes to deserialize
* Returns:
*   A libfp dynarray of opcodes; free it with `fp.dynarray.free`.
*/
Opcode* fromBinary(alias L = defaultLookup)(const(void)[] binary) @trusted {
	assert(binary.length % SerializationOpcode.sizeof == 0);
	immutable count = binary.length / SerializationOpcode.sizeof;

	Opcode* result = null;
	dynGrowToSize(result, count);

	auto source = cast(const(SerializationOpcode)*) binary.ptr;
	foreach (i; 0 .. count) {
		SerializationOpcode code = source[i];
		// The blob stores little-endian integers; swap if we are not.
		version(BigEndian) code.byteswap();
		// Turn the ID back into a pointer.
		code.op = cast(ulong) cast(size_t) L.lookupPointer(cast(Id) code.op);
		result[i] = code.toOpcode();
	}
	return result;
}

unittest {
	import mizu.instructions.core;

	static immutable Opcode[4] program = [
		Opcode(&loadImmediate, registers.t(0)).setImmediate(40),
		Opcode(&debugPrint, 0, registers.t(0)),
		Opcode(&add, 3, 2, 1),
		Opcode(&halt),
	];

	auto binary = toBinary(program[]);
	scope(exit) dynFree(binary);
	assert(ptrLength(binary) == 4 * SerializationOpcode.sizeof);

	auto restored = fromBinary(binary[0 .. ptrLength(binary)]);
	scope(exit) dynFree(restored);
	assert(ptrLength(restored) == 4);

	foreach (i; 0 .. 4) {
		assert(restored[i].op is program[i].op);
		assert(restored[i].out_ == program[i].out_);
		assert(restored[i].a == program[i].a);
		assert(restored[i].b == program[i].b);
	}
	assert(restored[0].immediate == 40);
}

unittest {
	// A null op (programEnd) survives the round trip as a null op.
	static immutable Opcode[1] program = [Opcode(null, 0, 0, 0)];

	auto binary = toBinary(program[]);
	scope(exit) dynFree(binary);
	auto restored = fromBinary(binary[0 .. ptrLength(binary)]);
	scope(exit) dynFree(restored);

	assert(restored[0].op is null);
}

unittest {
	// `byteswap` only runs on a big endian host, so call it directly. Every
	// field flips, and flipping twice is the identity.
	SerializationOpcode code;
	code.op = 0x0123456789ABCDEF;
	code.out_ = 0x1122;
	code.a = 0x3344;
	code.b = 0x5566;

	auto swapped = code;
	swapped.byteswap();
	assert(swapped.op == 0xEFCDAB8967452301);
	assert(swapped.out_ == 0x2211);
	assert(swapped.a == 0x4433);
	assert(swapped.b == 0x6655);

	swapped.byteswap();
	assert(swapped.op == code.op);
	assert(swapped.out_ == code.out_);
	assert(swapped.a == code.a);
	assert(swapped.b == code.b);
}
