/**
* Maps instructions between their names, their function pointers, and the
* small integer IDs the serializers write to disk.
*
* The C++ original built three `std::unordered_map`s at program startup: each
* instruction header declared a `bool <name>_registered` whose initializer
* called `register_instruction`. `-betterC` has no static constructors, so
* that trick is unavailable — and unnecessary. D can enumerate the
* instructions at compile time with `__traits(allMembers)`, so the table
* below is built during compilation and lives in read-only data. Nothing is
* allocated, nothing runs before `main`, and the C++
* `release_lookup_data()` has no counterpart because there is nothing to
* release.
*
* An instruction's ID is its index in that table, which makes IDs stable for
* a given build instead of depending on static initialization order across
* translation units.
*
* Warning:
*   IDs still describe one build configuration. Adding, removing or
*   reordering instructions renumbers everything after the change, so a
*   serialized program can only be loaded by a build with the same
*   instruction set. FFI instructions are placed last so that turning the
*   FFI on or off leaves the core instruction IDs untouched.
*/
module mizu.lookup;

import core.stdc.string : memcmp;

import mizu.config : noFFI;
import mizu.opcode;

import mizu.instructions.core;
import mizu.instructions.dbg;
import mizu.instructions.f32;
import mizu.instructions.f64;
import mizu.instructions.unsafe;
import mizu.instructions.parallel;
static if (!noFFI) import mizu.ffi.instructions;

@nogc nothrow:

/// An instruction's identifier in the lookup table.
alias Id = size_t;

/// Returned by the `lookupId` overloads when nothing matches.
enum Id notFound = Id.max;

/// One row of the lookup table.
struct Entry {
	/// The instruction's D identifier, null terminated so `.ptr` is printable.
	string name;
	/// The instruction itself; null for `programEnd`.
	Instruction ptr;
}

/// Our own, to avoid dragging `std.meta` into a `-betterC` build.
private template AliasSeq(Args...) { alias AliasSeq = Args; }

/**
* Every module whose instructions belong in the table, in ID order.
*
* The FFI comes last deliberately: see the warning in the module docs.
*/
private alias instructionModules = AliasSeq!(
	mizu.instructions.core,
	mizu.instructions.dbg,
	mizu.instructions.f32,
	mizu.instructions.f64,
	mizu.instructions.unsafe,
	mizu.instructions.parallel,
);

/// True if `mod`.`name` is an instruction `mod` itself declares.
private template isInstruction(alias mod, string name) {
	static if (__traits(compiles, __traits(getMember, mod, name)))
		enum bool isInstruction = __traits(compiles, {
			alias symbol = __traits(getMember, mod, name);
			static assert(__traits(isStaticFunction, symbol));
			// Selective imports show up in allMembers too; only count the
			// functions this module actually declares.
			static assert(__traits(isSame, __traits(parent, symbol), mod));
			Instruction check = &symbol;
		});
	else
		enum bool isInstruction = false;
}

/**
* The names of every instruction `mod` declares, in declaration order.
*
* This runs only during compilation, but it still has to obey the module's
* `@nogc`, which a `-betterC` build does not enforce on it and an ordinary D
* build does. Hence both the fixed size array (appending to a dynamic one
* allocates) and `expand` below.
*/
private template instructionsOf(alias mod) {
	private size_t countInstructions() {
		size_t total = 0;
		foreach (name; __traits(allMembers, mod))
			if (isInstruction!(mod, name))
				++total;
		return total;
	}
	private string[countInstructions()] collect() {
		typeof(return) names;
		size_t i = 0;
		foreach (name; __traits(allMembers, mod))
			if (isInstruction!(mod, name))
				names[i++] = name;
		return names;
	}
	private enum collected = collect();

	// Handed out as a sequence rather than as the array: `static foreach`
	// over an array has to build the sequence to walk it, and the way it
	// does that appends, which is a GC allocation this module forbids.
	// Iterating a sequence needs no such lowering.
	private template expand(size_t i) {
		static if (i == collected.length) alias expand = AliasSeq!();
		else alias expand = AliasSeq!(collected[i], expand!(i + 1));
	}
	alias instructionsOf = expand!0;
}

private enum size_t entryCount = () {
	size_t total = 1; // Slot zero is programEnd.
	static foreach (mod; instructionModules)
		total += instructionsOf!mod.length;
	static if (!noFFI)
		total += instructionsOf!(mizu.ffi.instructions).length;
	return total;
}();

private Entry[entryCount] buildTable() {
	Entry[entryCount] result;
	size_t i = 0;
	result[i++] = Entry("programEnd", null);
	static foreach (mod; instructionModules)
		static foreach (name; instructionsOf!mod)
			result[i++] = Entry(name, &__traits(getMember, mod, name));
	static if (!noFFI)
		static foreach (name; instructionsOf!(mizu.ffi.instructions))
			result[i++] = Entry(name, &__traits(getMember, mizu.ffi.instructions, name));
	return result;
}

/// Every known instruction, indexed by ID. Built at compile time.
immutable Entry[entryCount] table = buildTable();

/// How many instructions the lookup knows about (including `programEnd`).
enum size_t instructionCount = entryCount;

/// True if `id` names a row of `table`.
bool validId(Id id) { return id < entryCount; }

private bool sameName(scope const(char)[] a, scope const(char)[] b) @trusted {
	if (a.length != b.length) return false;
	if (a.length == 0) return true;
	return memcmp(a.ptr, b.ptr, a.length) == 0;
}

/**
* Finds an instruction's ID by name.
*
* Returns: the ID, or `notFound`.
*/
Id lookupId(scope const(char)[] name) {
	foreach (id; 0 .. entryCount)
		if (sameName(table[id].name, name))
			return id;
	return notFound;
}

/**
* Finds an instruction's ID by function pointer.
*
* Returns: the ID, or `notFound`. A null pointer is `programEnd`, ID zero.
*/
Id lookupId(Instruction ptr) {
	foreach (id; 0 .. entryCount)
		if (table[id].ptr is ptr)
			return id;
	return notFound;
}

/**
* Looks up an instruction's function pointer by ID.
*
* Returns:
*   The instruction, or null. Note that null is also the legitimate answer
*   for ID zero (`programEnd`); use `validId` to tell the two apart.
*/
Instruction lookupPointer(Id id) {
	if (!validId(id)) return null;
	return table[id].ptr;
}

/**
* Looks up an instruction's name by ID.
*
* Returns: the name, or a null slice if `id` is out of range.
*/
string lookupName(Id id) {
	if (!validId(id)) return null;
	return table[id].name;
}

/**
* Finds an instruction's function pointer by name.
*
* Returns: the instruction, or null if the name is unknown.
*/
Instruction lookup(scope const(char)[] name) {
	return lookupPointer(lookupId(name));
}

/**
* Finds an instruction's name by function pointer.
*
* Returns: the name, or a null slice if the pointer is unknown.
*/
string lookup(Instruction ptr) {
	return lookupName(lookupId(ptr));
}

unittest {
	// programEnd owns slot zero, so a null op round-trips through serialization.
	assert(lookupId(cast(Instruction) null) == 0);
	assert(lookupPointer(0) is null);
	assert(sameName(lookupName(0), "programEnd"));

	// Every core instruction is present, findable both ways, and agrees with itself.
	immutable id = lookupId("loadImmediate");
	assert(id != notFound);
	assert(lookupPointer(id) is &loadImmediate);
	assert(lookupId(&loadImmediate) == id);
	assert(sameName(lookup(&loadImmediate), "loadImmediate"));
	assert(lookup("loadImmediate") is &loadImmediate);

	// Instructions from every module made it in.
	assert(lookupId("add") != notFound);
	assert(lookupId("breakpoint") != notFound);
	assert(lookupId("addF32") != notFound);
	assert(lookupId("addF64") != notFound);
	assert(lookupId("copyMemory") != notFound);
	assert(lookupId("channelCreate") != notFound);

	// Helpers that are not instructions stayed out.
	assert(lookupId("floatRegister") == notFound);
	assert(lookupId("label2immediate") == notFound);
	assert(lookupId("newThread") == notFound);
	assert(lookupId("nosuchinstruction") == notFound);

	// No duplicate names or pointers.
	foreach (i; 0 .. instructionCount)
		foreach (j; i + 1 .. instructionCount) {
			assert(!sameName(table[i].name, table[j].name));
			assert(table[i].ptr !is table[j].ptr);
		}
}

unittest {
	// An instruction the table has never seen is `notFound` by either name,
	// and an out of range ID answers with nothing rather than row zero.
	static extern(C) void* stranger(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @nogc nothrow {
		return null;
	}

	assert(stranger(null, null, null, null) is null); // ... and it is a real one.
	assert(lookupId(cast(Instruction) &stranger) == notFound);
	assert(lookup(cast(Instruction) &stranger) is null);
	assert(!validId(notFound));
	assert(lookupName(notFound) is null);
	assert(lookupPointer(notFound) is null);

	// And the immutable table really is what `buildTable` builds.
	auto rebuilt = buildTable();
	foreach (i; 0 .. instructionCount) {
		assert(sameName(rebuilt[i].name, table[i].name));
		assert(rebuilt[i].ptr is table[i].ptr);
	}
}
