/**
* Maps instructions between their names, their function pointers, and the small integer IDs the serializers write to disk.
*
* The C++ original built three `std::unordered_map`s at program startup, each instruction header registering itself from a static initializer.
* `-betterC` has no static constructors, and needs none: D enumerates the instructions at compile time with `__traits(allMembers)`, so the table is built during compilation and lives in read-only data.
* Nothing is allocated, nothing runs before `main`, and there is nothing to release.
*
* An instruction's ID is its index in that table, which makes IDs stable for a given build instead of depending on static initialization order across translation units.
*
* $(H3 Names)
*
* The table stores fully qualified names: `mizu.instructions.core.add`, not `add`.
* Two packages may then both declare an `add` without one shadowing the other, and a name alone says where the instruction came from, which is what lets `mizu.portable_format.generateSourceFile` import exactly the modules a program needs.
* It is also what `__FUNCTION__` expands to, so a table name matches what a traced instruction prints under `MizuEnableTracing`.
* `lookupId` still accepts a bare name for convenience; see `unqualifiedName` and `moduleOfName` to take a stored name apart.
*
* $(H3 Adding your own instructions)
*
* The table is a template, `Lookup`, so a project that defines instructions of its own can build a table that knows about them too:
*
* ---
* module myproject.instructions;
* extern(C) void* myInstruction(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) { ... }
*
* alias myLookup = Lookup!(myproject.instructions);
* ---
*
* `myLookup` has the same members as this module's, with your instructions appended after Mizu's, so Mizu's own IDs are untouched and yours start at `myLookup.builtinCount`.
* Hand it to the serializers to make them resolve both halves: `fromBinary!myLookup(blob)`, `toPortable!myLookup(program)` and so on; every function in `mizu.serialize` and `mizu.portable_format` takes a lookup as its first template argument and defaults to `Lookup!()`.
*
* This has to be a template rather than a list of extra modules `mizu.lookup` imports: Mizu is usually compiled as its own static library, long before your instructions exist.
* A template is instantiated in $(I your) compilation instead, where the compiler can see both halves, and the resulting table is still built entirely at compile time.
*
* Warning: IDs still describe one build configuration.
* Adding, removing or reordering instructions renumbers everything after the change, so a serialized program can only be loaded by a build with the same instruction set.
* FFI instructions are placed last of Mizu's own so that turning the FFI on or off leaves the core instruction IDs untouched; extra instructions follow them, so a program that uses extras must be loaded by a build that agrees about the FFI as well.
*/
module mizu.lookup;

static import std.meta;

static import fp.pointer;
static import fp.string;

static import mizu.config;
static import mizu.opcode;

static import mizu.instructions.core;
static import mizu.instructions.dbg;
static import mizu.instructions.f32;
static import mizu.instructions.f64;
static import mizu.instructions.unsafe;
static import mizu.instructions.parallel;
static import mizu.instructions.atomic;
static import mizu.instructions.overflow;
static if (!mizu.config.noFFI) static import mizu.ffi.instructions;

@nogc nothrow:

/// An instruction's identifier in the lookup table.
alias Id = size_t;

/// One row of the lookup table.
struct Entry {
	/**
	* The instruction's fully qualified D name, `mizu.instructions.core.add` rather than `add`, null terminated so `.ptr` is printable.
	*
	* See_Also: `unqualifiedName`, `moduleOfName`
	*/
	string name;
	/// The instruction itself; null for `programEnd`.
	mizu.opcode.Instruction ptr;
}


// Every module of Mizu's own whose instructions belong in the table, in ID order; the FFI comes last, as the module documentation explains.
private alias ownModules = std.meta.AliasSeq!(
	mizu.instructions.core,
	mizu.instructions.dbg,
	mizu.instructions.f32,
	mizu.instructions.f64,
	mizu.instructions.unsafe,
	mizu.instructions.parallel,
	mizu.instructions.atomic,
	mizu.instructions.overflow,
);

static if (!mizu.config.noFFI)
	private alias builtinModules = std.meta.AliasSeq!(ownModules, mizu.ffi.instructions);
else
	private alias builtinModules = ownModules;

// True if `mod`.`name` is an instruction `mod` itself declares.
private template isInstruction(alias mod, string name) {
	static if (__traits(compiles, __traits(getMember, mod, name)))
		enum bool isInstruction = __traits(compiles, {
			alias symbol = __traits(getMember, mod, name);
			static assert(__traits(isStaticFunction, symbol));
			// Selective imports show up in allMembers too; only count the functions this module declares.
			static assert(__traits(isSame, __traits(parent, symbol), mod));
			mizu.opcode.Instruction check = &symbol;
		});
	else
		enum bool isInstruction = false;
}

// The names of every instruction `mod` declares, in declaration order, built without appending: an ordinary D build enforces `@nogc` on CTFE too.
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

	// A sequence rather than the array, since `static foreach` over an array lowers to a GC append.
	private template expand(size_t i) {
		static if (i == collected.length) alias expand = std.meta.AliasSeq!();
		else alias expand = std.meta.AliasSeq!(collected[i], expand!(i + 1));
	}
	alias instructionsOf = expand!0;
}

// How many instructions `Mods` declare between them.
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
* A lookup table over Mizu's instructions, plus the ones declared by the `Extra` modules.
*
* `Lookup!()` is the table this module's own `table`, `lookupId` and friends are aliases for; instantiate it with your instruction modules to extend it.
* See the module documentation.
*
* Examples:
* ---
* alias plain = Lookup!();
* static assert(plain.entryCount == plain.builtinCount);
* assert(plain.lookup("add") is &add);
* ---
*/
template Lookup(Extra...) {
	static foreach (mod; Extra)
		static assert(__traits(isModule, mod), "Lookup's arguments are the modules your instructions are declared in.");

	private alias allModules = std.meta.AliasSeq!(builtinModules, Extra);

	/// How many instructions the lookup knows about, including `programEnd` in slot zero.
	enum size_t entryCount = 1 + totalInstructions!allModules;

	/// How many of those are Mizu's own.
	/// `Extra`'s IDs start here.
	enum size_t builtinCount = 1 + totalInstructions!builtinModules;

	private Entry[entryCount] buildTable() {
		Entry[entryCount] result;
		size_t i = 0;
		result[i++] = Entry(__traits(fullyQualifiedName, mizu.instructions.core.programEnd), null);
		static foreach (mod; allModules)
			static foreach (name; instructionsOf!mod)
				result[i++] = Entry(__traits(fullyQualifiedName, __traits(getMember, mod, name)), &__traits(getMember, mod, name));
		assert(i == entryCount, "mizu: a lookup table that missed or repeated an instruction");
		return result;
	}

	/// Every known instruction, indexed by ID.
	/// Built at compile time.
	immutable Entry[entryCount] table = buildTable();

	/**
	* True if `id` names a row of `table`.
	*
	* Examples:
	* ---
	* assert(defaultLookup.validId(0));
	* assert(!defaultLookup.validId(fp.pointer.notFound));
	* ---
	*/
	bool validId(Id id) { return id < entryCount; }

	/**
	* True if `id` names an instruction one of the `Extra` modules declares.
	*
	* Examples:
	* ---
	* assert(!defaultLookup.isExtendedId(defaultLookup.lookupId("add")));
	* ---
	*/
	bool isExtendedId(Id id) { return id >= builtinCount && id < entryCount; }

	/**
	* Finds an instruction's ID by name.
	*
	* `name` may be fully qualified (`mizu.instructions.core.add`) or bare (`add`); a bare name matches the first row whose own final component matches, so qualify it when two packages declare the same instruction.
	*
	* Returns: the ID, or `fp.pointer.notFound`.
	*
	* Examples:
	* ---
	* assert(defaultLookup.lookupId("add") == defaultLookup.lookupId("mizu.instructions.core.add"));
	* assert(defaultLookup.lookupId("nosuchinstruction") == fp.pointer.notFound);
	* ---
	*/
	Id lookupId(scope const(char)[] name) {
		static assert(entryCount < fp.pointer.allocationRefused, "mizu: an instruction id that could read as a sentinel");
		foreach (id; 0 .. entryCount)
			if (fp.string.equal(table[id].name, name))
				return id;
		if (moduleOfName(name).length == 0)
			foreach (id; 0 .. entryCount)
				if (fp.string.equal(unqualifiedName(table[id].name), name))
					return id;
		return fp.pointer.notFound;
	}

	/**
	* Finds an instruction's ID by function pointer.
	*
	* Returns: the ID, or `fp.pointer.notFound`.
	* A null pointer is `programEnd`, ID zero.
	*
	* Examples:
	* ---
	* assert(defaultLookup.lookupId(&halt) != fp.pointer.notFound);
	* assert(defaultLookup.lookupId(cast(mizu.opcode.Instruction) null) == 0);
	* ---
	*/
	Id lookupId(mizu.opcode.Instruction ptr) {
		assert(table[0].ptr is null, "mizu: a lookup table whose first entry is not programEnd");
		foreach (id; 0 .. entryCount)
			if (table[id].ptr is ptr)
				return id;
		return fp.pointer.notFound;
	}

	/**
	* Looks up an instruction's function pointer by ID.
	*
	* Returns: the instruction, or null.
	* Null is also the legitimate answer for ID zero (`programEnd`); use `validId` to tell the two apart.
	*
	* Examples:
	* ---
	* assert(defaultLookup.lookupPointer(defaultLookup.lookupId("halt")) is &halt);
	* assert(defaultLookup.lookupPointer(fp.pointer.notFound) is null);
	* ---
	*/
	mizu.opcode.Instruction lookupPointer(Id id) {
		if (!validId(id)) return null;
		assert(id == 0 || table[id].ptr !is null, "mizu: an instruction other than programEnd with no function");
		return table[id].ptr;
	}

	/**
	* Looks up an instruction's name by ID.
	*
	* Returns: the name, or a null slice if `id` is out of range.
	*
	* Examples:
	* ---
	* assert(defaultLookup.lookupName(0) == "mizu.instructions.core.programEnd");
	* assert(defaultLookup.lookupName(fp.pointer.notFound) is null);
	* ---
	*/
	string lookupName(Id id) {
		if (!validId(id)) return null;
		assert(table[id].name.length > 0, "mizu: an instruction with no name");
		return table[id].name;
	}

	// wrapper: an instruction, or an accessor of the packed encoding the instruction set defines
	/**
	* Finds an instruction's function pointer by name.
	*
	* Returns: the instruction, or null if the name is unknown.
	*
	* Examples:
	* ---
	* assert(defaultLookup.lookup("halt") is &halt);
	* assert(defaultLookup.lookup("nosuchinstruction") is null);
	* ---
	*/
	mizu.opcode.Instruction lookup(scope const(char)[] name) {
		return lookupPointer(lookupId(name));
	}

	// wrapper: an instruction, or an accessor of the packed encoding the instruction set defines
	/**
	* Finds an instruction's name by function pointer.
	*
	* Returns: the name, or a null slice if the pointer is unknown.
	*
	* Examples:
	* ---
	* assert(defaultLookup.lookup(&halt) == "mizu.instructions.core.halt");
	* ---
	*/
	string lookup(mizu.opcode.Instruction ptr) {
		return lookupName(lookupId(ptr));
	}
}

/// The lookup over Mizu's own instructions, which the names below refer to.
/// Extended tables are `Lookup!(yourModule)`; see the module documentation.
alias defaultLookup = Lookup!();

/// Ditto `Lookup.table`
alias table = defaultLookup.table;
/// How many instructions the default lookup knows about, including `programEnd`.
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

/**
* The instruction half of a fully qualified `name`: everything after the last dot, or all of `name` if it has none.
*
* Examples:
* ---
* assert(unqualifiedName("mizu.instructions.core.add") == "add");
* assert(unqualifiedName("add") == "add");
* ---
*/
const(char)[] unqualifiedName(return scope const(char)[] name) {
	foreach_reverse (i, c; name)
		if (c == '.') return name[i + 1 .. $];
	return name;
}

/**
* The module half of a fully qualified `name`: everything before the last dot, or an empty slice if it has none.
*
* Examples:
* ---
* assert(moduleOfName("mizu.instructions.core.add") == "mizu.instructions.core");
* assert(moduleOfName("add").length == 0);
* ---
*/
const(char)[] moduleOfName(return scope const(char)[] name) {
	foreach_reverse (i, c; name)
		if (c == '.') return name[0 .. i];
	return name[0 .. 0];
}

unittest {
	// programEnd owns slot zero, so a null op round-trips through serialization.
	assert(lookupId(cast(mizu.opcode.Instruction) null) == 0);
	assert(lookupPointer(0) is null);
	assert(fp.string.equal(lookupName(0), "mizu.instructions.core.programEnd"));

	// Every core instruction is present, findable both ways, and agrees with itself.
	immutable id = lookupId("mizu.instructions.core.loadImmediate");
	assert(id != fp.pointer.notFound);
	assert(lookupPointer(id) is &mizu.instructions.core.loadImmediate);
	assert(lookupId(&mizu.instructions.core.loadImmediate) == id);
	assert(fp.string.equal(lookup(&mizu.instructions.core.loadImmediate), "mizu.instructions.core.loadImmediate"));
	assert(lookup("mizu.instructions.core.loadImmediate") is &mizu.instructions.core.loadImmediate);

	// A bare name still finds it, and a wrongly qualified one does not.
	assert(lookupId("loadImmediate") == id);
	assert(lookup("loadImmediate") is &mizu.instructions.core.loadImmediate);
	assert(lookupId("mizu.instructions.f32.loadImmediate") == fp.pointer.notFound);

	// Instructions from every module made it in, under their own module's name.
	assert(lookupId("add") != fp.pointer.notFound);
	assert(lookupId("breakpoint") != fp.pointer.notFound);
	assert(lookupId("addF32") != fp.pointer.notFound);
	assert(lookupId("addF64") != fp.pointer.notFound);
	assert(lookupId("copyMemory") != fp.pointer.notFound);
	assert(lookupId("channelCreate") != fp.pointer.notFound);
	assert(fp.string.equal(lookupName(lookupId("add")), "mizu.instructions.core.add"));
	assert(fp.string.equal(lookupName(lookupId("breakpoint")), "mizu.instructions.dbg.breakpoint"));
	assert(fp.string.equal(lookupName(lookupId("addF32")), "mizu.instructions.f32.addF32"));
	assert(fp.string.equal(lookupName(lookupId("addF64")), "mizu.instructions.f64.addF64"));
	assert(fp.string.equal(lookupName(lookupId("copyMemory")), "mizu.instructions.unsafe.copyMemory"));
	assert(fp.string.equal(lookupName(lookupId("channelCreate")), "mizu.instructions.parallel.channelCreate"));
	static if (!mizu.config.noFFI)
		assert(fp.string.equal(lookupName(lookupId("createInterface")), "mizu.ffi.instructions.createInterface"));

	// Helpers that are not instructions stayed out.
	assert(lookupId("floatRegister") == fp.pointer.notFound);
	assert(lookupId("labelToImmediate") == fp.pointer.notFound);
	assert(lookupId("newThread") == fp.pointer.notFound);
	assert(lookupId("nosuchinstruction") == fp.pointer.notFound);

	// Nothing of Mizu's own is an extended ID, and the two counts agree.
	assert(defaultLookup.builtinCount == instructionCount);
	foreach (i; 0 .. instructionCount)
		assert(!defaultLookup.isExtendedId(i));

	// No duplicate names or pointers.
	foreach (i; 0 .. instructionCount)
		foreach (j; i + 1 .. instructionCount) {
			assert(!fp.string.equal(table[i].name, table[j].name));
			assert(table[i].ptr !is table[j].ptr);
		}
}

unittest {
	// An instruction the table has never seen is `fp.pointer.notFound` by either name, and an out of range ID answers with nothing rather than row zero.
	static extern(C) void* stranger(mizu.opcode.Opcode* pc, ulong* registers, mizu.opcode.RegistersAndStack* env, ubyte* sp) @nogc nothrow {
		return null;
	}

	assert(stranger(null, null, null, null) is null); // ... and it is a real one.
	assert(lookupId(cast(mizu.opcode.Instruction) &stranger) == fp.pointer.notFound);
	assert(lookup(cast(mizu.opcode.Instruction) &stranger) is null);
	assert(!validId(fp.pointer.notFound));
	assert(lookupName(fp.pointer.notFound) is null);
	assert(lookupPointer(fp.pointer.notFound) is null);

	// And the immutable table really is what `buildTable` builds.
	auto rebuilt = defaultLookup.buildTable();
	foreach (i; 0 .. instructionCount) {
		assert(fp.string.equal(rebuilt[i].name, table[i].name));
		assert(rebuilt[i].ptr is table[i].ptr);
	}
}

version (unittest) private extern(C) void* testExtraInstruction(mizu.opcode.Opcode* pc, ulong* registers, mizu.opcode.RegistersAndStack* env, ubyte* sp) {
	return null;
}

unittest {
	// An extended table: Mizu's own IDs are untouched, and the extras follow.
	alias extended = Lookup!(mizu.lookup);

	assert(extended.builtinCount == instructionCount);
	assert(extended.entryCount > instructionCount);
	foreach (i; 0 .. instructionCount) {
		assert(fp.string.equal(extended.lookupName(i), lookupName(i)));
		assert(extended.lookupPointer(i) is lookupPointer(i));
	}

	immutable id = extended.lookupId("mizu.lookup.testExtraInstruction");
	assert(id != fp.pointer.notFound);
	assert(extended.lookupId("testExtraInstruction") == id);
	assert(fp.string.equal(extended.lookupName(id), "mizu.lookup.testExtraInstruction"));
	assert(id >= extended.builtinCount);
	assert(extended.isExtendedId(id));
	assert(extended.lookupPointer(id) is cast(mizu.opcode.Instruction) &testExtraInstruction);
	assert(extended.lookupId(cast(mizu.opcode.Instruction) &testExtraInstruction) == id);

	// The unextended table knows nothing about it.
	assert(lookupId("mizu.lookup.testExtraInstruction") == fp.pointer.notFound);
	assert(lookupId("testExtraInstruction") == fp.pointer.notFound);
	assert(lookupId(cast(mizu.opcode.Instruction) &testExtraInstruction) == fp.pointer.notFound);
	assert(testExtraInstruction(null, null, null, null) is null); // a real instruction, ending the program
}

unittest {
	// Every stored name is qualified by its module, and still null terminated, so `Entry.name`'s promise that `.ptr` is printable holds.
	foreach (i; 0 .. instructionCount) {
		auto name = table[i].name;
		assert(moduleOfName(name).length > 0);
		assert(unqualifiedName(name).length > 0);
		assert(name.ptr[name.length] == '\0');
	}

	// Taking a name apart, and the degenerate cases.
	assert(fp.string.equal(moduleOfName("mizu.instructions.core.add"), "mizu.instructions.core"));
	assert(fp.string.equal(unqualifiedName("mizu.instructions.core.add"), "add"));
	assert(moduleOfName("add").length == 0);
	assert(fp.string.equal(unqualifiedName("add"), "add"));
	assert(moduleOfName("").length == 0);
	assert(unqualifiedName("").length == 0);
}
