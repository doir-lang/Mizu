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
* $(H3 Names)
*
* Unlike the C++ original, which registered each instruction under its bare
* identifier, the table stores fully qualified names:
* `mizu.instructions.core.add`, not `add`. Two packages may then both declare
* an `add` without one shadowing the other, and a name is enough on its own
* to say where the instruction came from — which is what lets
* `mizu.portable_format.generateSourceFile` emit a file that imports exactly
* the modules the program needs. It is also what `__FUNCTION__` expands to,
* so a table name and the name a traced instruction prints under
* `MizuEnableTracing` are now the same string. `lookupId` still accepts a
* bare name for convenience; see `unqualifiedName` and `moduleOfName` to take
* a stored name apart.
*
* $(H3 Adding your own instructions)
*
* The table is a template, `Lookup`, so a project that defines instructions
* of its own can build a table that knows about them too:
*
* ---
* module myproject.instructions;
* extern(C) void* myInstruction(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) { ... }
*
* alias myLookup = Lookup!(myproject.instructions);
* ---
*
* `myLookup` has the same members as this module's, with your instructions
* appended after Mizu's, so Mizu's own IDs are untouched and yours start at
* `myLookup.builtinCount`. Hand it to the serializers to make them resolve
* both halves — `fromBinary!myLookup(blob)`, `toPortable!myLookup(program)`
* and so on; every function in `mizu.serialize` and `mizu.portable_format`
* takes a lookup as its first template argument and defaults to `Lookup!()`.
*
* This has to be a template rather than, say, a list of extra modules
* `mizu.lookup` imports: Mizu is usually compiled as its own static library,
* long before your instructions exist. A template is instantiated in *your*
* compilation instead, where the compiler can see both halves, and the
* resulting table is still built entirely at compile time.
*
* Warning:
*   IDs still describe one build configuration. Adding, removing or
*   reordering instructions renumbers everything after the change, so a
*   serialized program can only be loaded by a build with the same
*   instruction set. FFI instructions are placed last of Mizu's own so that
*   turning the FFI on or off leaves the core instruction IDs untouched;
*   extra instructions follow them, so a program that uses extras must be
*   loaded by a build that agrees about the FFI as well.
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
	/**
	* The instruction's fully qualified D name — `mizu.instructions.core.add`,
	* not `add` — null terminated so `.ptr` is printable.
	*
	* See_Also: `unqualifiedName`, `moduleOfName`
	*/
	string name;
	/// The instruction itself; null for `programEnd`.
	Instruction ptr;
}

/// Our own, to avoid dragging `std.meta` into a `-betterC` build.
private template AliasSeq(Args...) { alias AliasSeq = Args; }

/**
* Every module of Mizu's own whose instructions belong in the table, in ID
* order.
*
* The FFI comes last deliberately: see the warning in the module docs.
*/
static if (!noFFI)
	private alias builtinModules = AliasSeq!(
		mizu.instructions.core,
		mizu.instructions.dbg,
		mizu.instructions.f32,
		mizu.instructions.f64,
		mizu.instructions.unsafe,
		mizu.instructions.parallel,
		mizu.ffi.instructions,
	);
else
	private alias builtinModules = AliasSeq!(
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

/// How many instructions `Mods` declare between them.
private template totalInstructions(Mods...) {
	private enum size_t count = () {
		size_t total = 0;
		static foreach (mod; Mods)
			total += instructionsOf!mod.length;
		return total;
	}();
	alias totalInstructions = count;
}

/**
* A lookup table over Mizu's instructions, plus the ones declared by the
* `Extra` modules.
*
* `Lookup!()` is the table this module's own `table`, `lookupId` and friends
* are aliases for; instantiate it with your instruction modules to extend it.
* See the module documentation.
*/
template Lookup(Extra...) {
	static foreach (mod; Extra)
		static assert(__traits(isModule, mod),
			"Lookup's arguments are the modules your instructions are declared in.");

	private alias allModules = AliasSeq!(builtinModules, Extra);

	/// How many instructions the lookup knows about (including `programEnd`).
	enum size_t entryCount = 1 + totalInstructions!allModules; // Slot zero is programEnd.

	/// How many of those are Mizu's own. `Extra`'s IDs start here.
	enum size_t builtinCount = 1 + totalInstructions!builtinModules;

	private Entry[entryCount] buildTable() {
		Entry[entryCount] result;
		size_t i = 0;
		result[i++] = Entry(__traits(fullyQualifiedName, mizu.instructions.core.programEnd), null);
		static foreach (mod; allModules)
			static foreach (name; instructionsOf!mod)
				result[i++] = Entry(
					__traits(fullyQualifiedName, __traits(getMember, mod, name)),
					&__traits(getMember, mod, name));
		return result;
	}

	/// Every known instruction, indexed by ID. Built at compile time.
	immutable Entry[entryCount] table = buildTable();

	/// True if `id` names a row of `table`.
	bool validId(Id id) { return id < entryCount; }

	/// True if `id` names an instruction one of the `Extra` modules declares.
	bool isExtendedId(Id id) { return id >= builtinCount && id < entryCount; }

	/**
	* Finds an instruction's ID by name.
	*
	* `name` may be fully qualified (`mizu.instructions.core.add`) or bare
	* (`add`); a bare name matches the first row whose own final component
	* matches, so qualify it when two packages declare the same instruction.
	*
	* Returns: the ID, or `notFound`.
	*/
	Id lookupId(scope const(char)[] name) {
		foreach (id; 0 .. entryCount)
			if (sameName(table[id].name, name))
				return id;
		if (moduleOfName(name).length == 0)
			foreach (id; 0 .. entryCount)
				if (sameName(unqualifiedName(table[id].name), name))
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
}

/// The lookup over Mizu's own instructions, which is what the names below
/// refer to. Extended tables are `Lookup!(yourModule)`; see the module docs.
alias defaultLookup = Lookup!();

/// Ditto `Lookup.table`
alias table = defaultLookup.table;
/// How many instructions the lookup knows about (including `programEnd`).
enum size_t instructionCount = defaultLookup.entryCount;
/// Ditto `Lookup.validId`
alias validId = defaultLookup.validId;
/// Ditto `Lookup.lookupId`
alias lookupId = defaultLookup.lookupId;
/// Ditto `Lookup.lookupPointer`
alias lookupPointer = defaultLookup.lookupPointer;
/// Ditto `Lookup.lookupName`
alias lookupName = defaultLookup.lookupName;
/// Ditto `Lookup.lookup`
alias lookup = defaultLookup.lookup;

/// True if `a` and `b` are the same sequence of characters.
bool sameName(scope const(char)[] a, scope const(char)[] b) @trusted {
	if (a.length != b.length) return false;
	if (a.length == 0) return true;
	return memcmp(a.ptr, b.ptr, a.length) == 0;
}

/**
* The instruction half of a fully qualified `name`: everything after the last
* dot, or all of `name` if it has none.
*/
const(char)[] unqualifiedName(return scope const(char)[] name) {
	foreach_reverse (i, c; name)
		if (c == '.') return name[i + 1 .. $];
	return name;
}

/**
* The module half of a fully qualified `name`: everything before the last
* dot, or an empty slice if it has none.
*/
const(char)[] moduleOfName(return scope const(char)[] name) {
	foreach_reverse (i, c; name)
		if (c == '.') return name[0 .. i];
	return name[0 .. 0];
}

unittest {
	// programEnd owns slot zero, so a null op round-trips through serialization.
	assert(lookupId(cast(Instruction) null) == 0);
	assert(lookupPointer(0) is null);
	assert(sameName(lookupName(0), "mizu.instructions.core.programEnd"));

	// Every core instruction is present, findable both ways, and agrees with itself.
	immutable id = lookupId("mizu.instructions.core.loadImmediate");
	assert(id != notFound);
	assert(lookupPointer(id) is &loadImmediate);
	assert(lookupId(&loadImmediate) == id);
	assert(sameName(lookup(&loadImmediate), "mizu.instructions.core.loadImmediate"));
	assert(lookup("mizu.instructions.core.loadImmediate") is &loadImmediate);

	// A bare name still finds it, and a wrongly qualified one does not.
	assert(lookupId("loadImmediate") == id);
	assert(lookup("loadImmediate") is &loadImmediate);
	assert(lookupId("mizu.instructions.f32.loadImmediate") == notFound);

	// Instructions from every module made it in, under their own module's name.
	assert(lookupId("add") != notFound);
	assert(lookupId("breakpoint") != notFound);
	assert(lookupId("addF32") != notFound);
	assert(lookupId("addF64") != notFound);
	assert(lookupId("copyMemory") != notFound);
	assert(lookupId("channelCreate") != notFound);
	assert(sameName(lookupName(lookupId("add")), "mizu.instructions.core.add"));
	assert(sameName(lookupName(lookupId("breakpoint")), "mizu.instructions.dbg.breakpoint"));
	assert(sameName(lookupName(lookupId("addF32")), "mizu.instructions.f32.addF32"));
	assert(sameName(lookupName(lookupId("addF64")), "mizu.instructions.f64.addF64"));
	assert(sameName(lookupName(lookupId("copyMemory")), "mizu.instructions.unsafe.copyMemory"));
	assert(sameName(lookupName(lookupId("channelCreate")), "mizu.instructions.parallel.channelCreate"));
	static if (!noFFI)
		assert(sameName(lookupName(lookupId("createInterface")), "mizu.ffi.instructions.createInterface"));

	// Helpers that are not instructions stayed out.
	assert(lookupId("floatRegister") == notFound);
	assert(lookupId("label2immediate") == notFound);
	assert(lookupId("newThread") == notFound);
	assert(lookupId("nosuchinstruction") == notFound);

	// Nothing of Mizu's own is an extended ID, and the two counts agree.
	assert(defaultLookup.builtinCount == instructionCount);
	foreach (i; 0 .. instructionCount)
		assert(!defaultLookup.isExtendedId(i));

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
	auto rebuilt = defaultLookup.buildTable();
	foreach (i; 0 .. instructionCount) {
		assert(sameName(rebuilt[i].name, table[i].name));
		assert(rebuilt[i].ptr is table[i].ptr);
	}
}

version (unittest) private extern(C) void* testExtraInstruction(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @nogc nothrow {
	return null;
}

unittest {
	// An extended table: Mizu's own IDs are untouched, and the extras follow.
	alias extended = Lookup!(mizu.lookup);

	assert(extended.builtinCount == instructionCount);
	assert(extended.entryCount > instructionCount);
	foreach (i; 0 .. instructionCount) {
		assert(sameName(extended.lookupName(i), lookupName(i)));
		assert(extended.lookupPointer(i) is lookupPointer(i));
	}

	immutable id = extended.lookupId("mizu.lookup.testExtraInstruction");
	assert(id != notFound);
	assert(extended.lookupId("testExtraInstruction") == id);
	assert(sameName(extended.lookupName(id), "mizu.lookup.testExtraInstruction"));
	assert(id >= extended.builtinCount);
	assert(extended.isExtendedId(id));
	assert(extended.lookupPointer(id) is cast(Instruction) &testExtraInstruction);
	assert(extended.lookupId(cast(Instruction) &testExtraInstruction) == id);

	// The unextended table knows nothing about it.
	assert(lookupId("mizu.lookup.testExtraInstruction") == notFound);
	assert(lookupId("testExtraInstruction") == notFound);
	assert(lookupId(cast(Instruction) &testExtraInstruction) == notFound);
}

unittest {
	// Every stored name is qualified by the module that declares the
	// instruction, and is still a null terminated literal, so `Entry.name`'s
	// promise that `.ptr` is printable survives being built by a trait.
	foreach (i; 0 .. instructionCount) {
		auto name = table[i].name;
		assert(moduleOfName(name).length > 0);
		assert(unqualifiedName(name).length > 0);
		assert(name.ptr[name.length] == '\0');
	}

	// Taking a name apart, and the degenerate cases.
	assert(sameName(moduleOfName("mizu.instructions.core.add"), "mizu.instructions.core"));
	assert(sameName(unqualifiedName("mizu.instructions.core.add"), "add"));
	assert(moduleOfName("add").length == 0);
	assert(sameName(unqualifiedName("add"), "add"));
	assert(moduleOfName("").length == 0);
	assert(unqualifiedName("").length == 0);
}
