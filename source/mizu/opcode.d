/**
* The core Mizu types: the register file, the `Opcode` an instruction acts
* on, the environment holding a program's registers and stack, and the
* dispatch mixin (`mizuNext`) every instruction ends with.
*/
module mizu.opcode;

import core.stdc.string : memcpy;

import fp.pointer : Array, ptrLength = length;

import mizu.config;
import mizu.exception : fatal;

version(DigitalMars) pragma(msg,
	"mizu: warning - DMD does not perform tail call optimization, so Mizu's "
	~ "dispatch will overflow the stack at run time. Build with LDC "
	~ "(--compiler=ldc2) and an optimization level of at least -O1.");

@nogc nothrow:

/// Type used to name a register inside an `Opcode`.
alias Reg = ushort;

/**
* The register file.
*
* $(UL
*   $(LI `x0` (`zero`) is always zero.)
*   $(LI `x1`-`x20` (`t0`-`t19`) are temporaries, saved by the caller if needed.)
*   $(LI `x21` (`ra`) is the return address (callee saved).)
*   $(LI `x22`-`x256` (`a0`-`a234`) are the argument registers (callee saved).))
*
* Note:
*   `a0`/`x22` and `a1`/`x23` are the canonical return registers.
*
* This is a `struct` used purely as a namespace, mirroring the C++
* `mizu::registers` inline namespace, so that call sites read
* `registers.t(0)` the way they used to read `mizu::registers::t(0)`.
*/
struct Registers {
	@disable this();
static @nogc nothrow:

	/// Generic register lookup; `i` is the register's index.
	Reg x(size_t i) { return cast(Reg) i; }

	/// Temporary register lookup; `i` is the temporary's index (0-19).
	Reg t(size_t i) in(i <= 20) { return cast(Reg)(i + 1); }

	/// Argument register lookup; `i` is the argument's index.
	Reg a(size_t i) { return cast(Reg)(i + 22); }

	/// The always-zero register.
	enum Reg zero = 0;
	/// The return address register.
	enum Reg returnAddress = 21;
	/// Ditto
	alias ra = returnAddress;
}

/**
* Spelling of `Registers` that matches the C++ `mizu::registers` namespace.
*
* Note:
*   Inside an instruction the `registers` parameter shadows this alias, so
*   instruction bodies say `Registers.a(0)`.
*/
alias registers = Registers;

/**
* The interface every instruction implements.
*
* `extern(C)` is not cosmetic: every instruction tail-calls the next one
* through this pointer, and a tail call is only possible between functions
* that agree on their calling convention.
*/
alias Instruction = extern(C) void* function(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @nogc nothrow;

/**
* An instruction plus (up to) three registers for it to act upon.
*
* Note:
*   Since `Instruction` is a pointer this struct has different sizes on
*   different machines, so Mizu binaries are only compatible with machines
*   of the same pointer size and endianness.
*
* The immediate accessors pack a 32 bit value into the `a`/`b` register
* fields as `a = low half, b = high half`. The C++ original reinterpreted
* the two fields as one `uint32_t`, which is the same thing on a
* little-endian machine but cannot be constant-folded in D, so the halves
* are written explicitly — which also makes the packing independent of host
* endianness and lets whole programs live in read-only data.
*/
struct Opcode {
@nogc nothrow:
	/// Instruction to perform.
	Instruction op;
	/// Register to store the instruction's result in.
	Reg out_;
	/// Register storing the first argument.
	Reg a;
	/// Register storing the second argument.
	Reg b;

	/// The `u32` immediate held in `a` and `b`.
	uint immediate() const { return a | (cast(uint) b << 16); }
	/// Replaces `a` and `b` with a `u32` immediate value.
	Opcode setImmediate(uint value) {
		a = cast(Reg)(value & 0xFFFF);
		b = cast(Reg)(value >> 16);
		return this;
	}

	/// The `i32` immediate held in `a` and `b`.
	int immediateSigned() const { return cast(int) immediate; }
	/// Replaces `a` and `b` with an `i32` immediate value.
	Opcode setImmediateSigned(int value) { return setImmediate(cast(uint) value); }

	/// The `i16` immediate held in `b`, used for branch offsets.
	short branchImmediate() const { return cast(short) b; }
	/// Replaces `b` with an `i16` immediate value (used to determine branch offsets).
	Opcode setBranchImmediate(short value) { b = cast(Reg) value; return this; }

	/// The `f32` immediate held in `a` and `b`.
	float immediateF32() const {
		immutable bits = immediate;
		return *cast(const float*) &bits;
	}
	/// Replaces `a` and `b` with an `f32` immediate value.
	Opcode setImmediateF32(float value) { return setImmediate(*cast(uint*) &value); }

	/// Replaces `a` and `b` with the lower half of an `f64` immediate value.
	Opcode setLowerImmediateF64(double value) {
		return setImmediate(cast(uint)(*cast(ulong*) &value));
	}
	/// Replaces `a` and `b` with the upper half of an `f64` immediate value.
	Opcode setUpperImmediateF64(double value) {
		return setImmediate(cast(uint)((*cast(ulong*) &value) >> 32));
	}

	/// Replaces `a` and `b` with the lower half of a host pointer.
	Opcode setHostPointerLowerImmediate(const(void)* ptr) {
		return setImmediate(cast(uint) cast(size_t) ptr);
	}
	/// Replaces `a` and `b` with the upper half of a host pointer.
	Opcode setHostPointerUpperImmediate(const(void)* ptr) {
		static if (size_t.sizeof > uint.sizeof)
			return setImmediate(cast(uint)((cast(size_t) ptr) >> 32));
		else
			return setImmediate(0);
	}
}

/**
* How many registers long a Mizu environment's memory space is.
* See_Also: `mizu.config.stackSizeKilobytes`
*/
enum size_t memorySize = cast(size_t)(1024 * stackSizeKilobytes) / ulong.sizeof;
/// How many bytes a Mizu environment's memory space is.
enum size_t memorySizeBytes = memorySize * ulong.sizeof;

/// The registers and stack space backing one Mizu program or thread.
struct RegistersAndStack {
@nogc nothrow:
	/**
	* Memory holding both the registers and the stack.
	* See_Also: `mizu.config.stackSizeKilobytes`
	*/
	Array!(ulong, memorySize) memory;
	/// Boundary between the stack and the registers.
	ubyte* stackBoundary;
	/**
	* The bottom (last byte) of the stack.
	*
	* Note: Mizu's stack pointer counts down from the last byte of `memory`
	* until it reaches `stackBoundary`.
	*/
	ubyte* stackBottom;

	/// Start of the program, or null if unknown.
	const(Opcode)* programStart = null;
	/// End of the program, or null if unknown.
	const(Opcode)* programEnd = null;

	/// Where the program starts, estimated from `pc` when unknown.
	const(Opcode)* calculateProgramStart(const(Opcode)* pc) const {
		return programStart ? programStart : pc - maximumLabelSearch;
	}
	/// Where the program ends, estimated from `pc` when unknown.
	const(Opcode)* calculateProgramEnd(const(Opcode)* pc) const {
		return programEnd ? programEnd : pc + maximumLabelSearch;
	}
}

/**
* Configures a new Mizu environment, zeroing register `x0`.
*
* Params:
*   env = the environment to configure
*   programStart = pointer to the start of the program (optional)
*   programEnd = pointer to one past the end of the program (optional)
*/
void setupEnvironment(ref RegistersAndStack env, const(Opcode)* programStart = null, const(Opcode)* programEnd = null) @trusted {
	env.memory[0] = 0;
	env.stackBoundary = cast(ubyte*)(env.memory.ptr + 256);
	env.stackBottom = cast(ubyte*)(env.memory.ptr + memorySize);
	env.programStart = programStart;
	env.programEnd = programEnd;
}

/// Ditto, taking the whole program as a slice.
void setupEnvironment(ref RegistersAndStack env, const(Opcode)[] program) @trusted {
	setupEnvironment(env, program.ptr, program.ptr + program.length);
}

/**
* Copies `binary` into the bottom of an environment's stack.
*
* Params:
*   env = the environment to copy data into
*   binary = the data to fill the bottom of its stack with
*/
void fillStackBottom(ref RegistersAndStack env, const(void)[] binary) @trusted {
	assert(binary.length <= memorySizeBytes);
	auto end = cast(ubyte*)(env.memory.ptr + memorySize);
	memcpy(end - binary.length, binary.ptr, binary.length);
}

/**
* Traces one instruction to stdout. Only does anything when the
* `MizuEnableTracing` version is set.
*/
void trace(scope const(char)[] name, const(Opcode)* pc) @trusted {
	static if (enableTracing) {
		import core.stdc.stdio : printf;
		printf("%.*s(%u, %u, %u)\n", cast(int) name.length, name.ptr,
			pc.out_, pc.a, pc.b);
	}
}

/**
* Executes the next instruction. Mix this in at the end of every
* instruction: `mixin(mizuNext);`
*
* This is the D spelling of the C++ `MIZU_NEXT()` macro. It has to be a
* mixin rather than a function because the dispatch must be a tail call
* made by the instruction itself — see the tail call notes in the README.
*/
static if (noHardwareThreads)
	enum string mizuNext = q{
		{
			mizu.opcode.trace(__FUNCTION__, pc);
			registers[0] = 0;
			return mizu.opcode.Coroutine.next(pc, registers, env, sp);
		}
	};
else
	enum string mizuNext = q{
		{
			mizu.opcode.trace(__FUNCTION__, pc);
			registers[0] = 0;
			++pc;
			return pc.op(pc, registers, env, sp);
		}
	};

static if (!noHardwareThreads) {

	/**
	* Starts executing `program` in `env`.
	*
	* Returns: whatever the program's final instruction returned (null for `halt`).
	*/
	void* startFromEnvironment(const(Opcode)* program, ref RegistersAndStack env) @trusted {
		auto pc = cast(Opcode*) program;
		return pc.op(pc, env.memory.ptr, &env, env.stackBottom);
	}

} else {

	/**
	* The single-core fallback for `mizu.instructions.parallel`: instead of OS
	* threads, every "thread" is an execution context and `next` round-robins
	* between them, so an instruction that cannot make progress yet just
	* rewinds its own program counter and yields.
	*/
	struct Coroutine {
		/// One suspended (or running) Mizu thread.
		static struct ExecutionContext {
		@nogc nothrow:
			/// Null marks a context that has run to completion.
			Opcode* programCounter;
			ubyte* stackPointer;
			RegistersAndStack* environment;

			/// True once this context has halted.
			bool done() const { return programCounter is null; }
		}

		/// All live contexts, as an `fp.dynarray`.
		__gshared ExecutionContext* contexts = null;
		/// Index of the context currently executing.
		__gshared size_t currentContext = 0;

	static @nogc nothrow:

		/// Advances `currentContext` to the next context, wrapping around.
		size_t nextContext() {
			return currentContext = (currentContext + 1) % ptrLength(contexts);
		}

		/// The context at `index`.
		ref ExecutionContext getContext(size_t index) @trusted
		in(index < ptrLength(contexts))
		{
			return contexts[index];
		}

		/// The context currently executing.
		ref ExecutionContext getCurrentContext() { return getContext(currentContext); }

		/**
		* Suspends the running context and resumes the next one that still has
		* work to do.
		*
		* Note: shares `Instruction`'s signature so instructions can tail-call it.
		*/
		extern(C) void* next(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
			assert(sp);
			getCurrentContext().stackPointer = sp;

			if (ptrLength(contexts) == 1) {
				getCurrentContext().programCounter = ++pc;
				return pc.op(pc, registers, env, sp);
			}
			// Record pc updates (jumps) before switching away.
			getCurrentContext().programCounter = pc;

			// Find the next context with work left; unlike the C++ original
			// this is a loop rather than recursion, so an all-finished
			// context list terminates instead of overflowing the stack.
			immutable start = currentContext;
			do {
				auto index = nextContext();
				auto context = &getContext(index);
				if (context.programCounter is null) continue;

				pc = ++context.programCounter;
				return pc.op(pc, context.environment.memory.ptr, context.environment,
					context.stackPointer);
			} while (currentContext != start);

			return null; // Every context has halted.
		}

		/// Registers a new context beginning at `programCounter`.
		void start(Opcode* programCounter, RegistersAndStack* environment) @trusted {
			import fp.dynarray : pushBack;
			assert(programCounter && environment);
			pushBack(contexts, ExecutionContext(programCounter - 1,
				environment.stackBottom, environment));
		}

		/// Releases every context.
		void clear() @trusted {
			import fp.dynarray : dynFree = free;
			if (contexts !is null) dynFree(contexts);
			currentContext = 0;
		}

		/// True once every context has halted.
		bool done() @trusted {
			foreach (i; 0 .. ptrLength(contexts))
				if (!getContext(i).done())
					return false;
			return true;
		}
	}

	/// Ditto
	void* startFromEnvironment(const(Opcode)* program, ref RegistersAndStack env) @trusted {
		Coroutine.start(cast(Opcode*) program, &env);

		void* result;
		do {
			auto context = &Coroutine.getCurrentContext();
			result = Coroutine.next(context.programCounter, context.environment.memory.ptr,
				context.environment, context.stackPointer);
		} while (result is null && !Coroutine.done());

		Coroutine.clear();
		return result;
	}

}

/// Ditto, taking the whole program as a slice.
void* startFromEnvironment(const(Opcode)[] program, ref RegistersAndStack env) {
	return startFromEnvironment(program.ptr, env);
}

unittest {
	// Registers follow RISC-V's layout: x0 is zero, t0..t19 then ra, then a0...
	static assert(Registers.zero == 0);
	static assert(Registers.t(0) == 1);
	static assert(Registers.t(19) == 20);
	static assert(Registers.returnAddress == 21);
	static assert(Registers.ra == 21);
	static assert(Registers.a(0) == 22);
	static assert(Registers.a(1) == 23);
	static assert(Registers.x(7) == 7);
}

unittest {
	// Immediates pack into the a/b register pair and read back unchanged, at
	// compile time, so a program full of them can live in read-only data.
	static assert(Opcode.init.setImmediate(40).immediate == 40);
	static assert(Opcode.init.setImmediate(uint.max).immediate == uint.max);
	static assert(Opcode.init.setImmediate(0xDEADBEEF).immediate == 0xDEADBEEF);
	// Low half in `a`, high half in `b`.
	static assert(Opcode.init.setImmediate(0xDEADBEEF).a == 0xBEEF);
	static assert(Opcode.init.setImmediate(0xDEADBEEF).b == 0xDEAD);

	static assert(Opcode.init.setImmediateSigned(-1).immediateSigned == -1);
	static assert(Opcode.init.setImmediateSigned(int.min).immediateSigned == int.min);

	static assert(Opcode.init.setBranchImmediate(-2).branchImmediate == -2);
	static assert(Opcode.init.setBranchImmediate(short.min).branchImmediate == short.min);
	static assert(Opcode.init.setBranchImmediate(short.max).branchImmediate == short.max);

	static assert(Opcode.init.setImmediateF32(1.5f).immediateF32 == 1.5f);
	static assert(Opcode.init.setImmediateF32(-0.125f).immediateF32 == -0.125f);
}

unittest {
	// An f64 immediate takes two instructions, so check the halves recombine.
	enum double value = 1234.5678;
	enum Opcode lower = Opcode.init.setLowerImmediateF64(value);
	enum Opcode upper = Opcode.init.setUpperImmediateF64(value);

	immutable ulong bits = lower.immediate | (cast(ulong) upper.immediate << 32);
	assert(*cast(const double*)&bits == value);
}

unittest {
	// setupEnvironment lays out the memory space the way the instructions expect.
	static immutable Opcode[2] program = [Opcode.init, Opcode.init];

	RegistersAndStack env;
	setupEnvironment(env, program[]);

	assert(env.memory[0] == 0);
	assert(env.stackBoundary is cast(ubyte*)(env.memory.ptr + 256));
	assert(env.stackBottom is cast(ubyte*)(env.memory.ptr + memorySize));
	assert(env.stackBottom - env.stackBoundary == (memorySize - 256) * ulong.sizeof);
	assert(env.programStart is program.ptr);
	assert(env.programEnd is program.ptr + 2);

	// And with no program given, the label search bounds straddle the pc.
	RegistersAndStack bare;
	setupEnvironment(bare);
	auto pc = cast(const(Opcode)*) program.ptr;
	assert(bare.calculateProgramStart(pc) is pc - maximumLabelSearch);
	assert(bare.calculateProgramEnd(pc) is pc + maximumLabelSearch);
}

unittest {
	// fillStackBottom puts data where pointerToStackBottom will find it.
	RegistersAndStack env;
	setupEnvironment(env);

	static immutable ubyte[4] data = [0xDE, 0xAD, 0xBE, 0xEF];
	fillStackBottom(env, data[]);

	auto bottom = env.stackBottom - data.length;
	foreach (i; 0 .. data.length)
		assert(bottom[i] == data[i]);
}

unittest {
	// The same packing at run time. The `static assert`s above only prove the
	// CTFE path, and a program assembled at run time (as the bubble sort test
	// does) takes this one instead. The inputs are `__gshared` so that the
	// optimizer cannot quietly constant fold the calls back into CTFE.
	__gshared uint immediate = 0xDEADBEEF;
	__gshared int signed = int.min;
	__gshared short branch = -2;
	__gshared float single = 1.5f;
	__gshared double dbl = 1234.5678;
	__gshared size_t index = 7;

	auto code = Opcode.init.setImmediate(immediate);
	assert(code.immediate == 0xDEADBEEF);
	assert(code.a == 0xBEEF); // Low half in `a`, high half in `b`.
	assert(code.b == 0xDEAD);

	assert(Opcode.init.setImmediateSigned(signed).immediateSigned == int.min);
	assert(Opcode.init.setBranchImmediate(branch).branchImmediate == -2);
	assert(Opcode.init.setImmediateF32(single).immediateF32 == 1.5f);

	// An f64 immediate takes two opcodes, so check the halves recombine.
	immutable lower = Opcode.init.setLowerImmediateF64(dbl);
	immutable upper = Opcode.init.setUpperImmediateF64(dbl);
	immutable ulong bits = lower.immediate | (cast(ulong) upper.immediate << 32);
	assert(*cast(const double*)&bits == dbl);

	// `x` is the generic spelling the named register accessors shorten.
	assert(Registers.x(index) == 7);
}

static if (noHardwareThreads)
unittest {
	// `Coroutine.next` giving up when nothing is left to run.
	//
	// `startFromEnvironment` never lets this happen — it checks `done()`
	// before scheduling again — so the case is reached by driving the
	// scheduler directly. It is worth holding onto: the search is a loop
	// rather than the C++ original's recursion precisely so that an
	// all-finished context list returns instead of overflowing the stack.
	Coroutine.clear();

	Opcode instruction;
	RegistersAndStack env;
	setupEnvironment(env, &instruction, &instruction + 1);
	Coroutine.start(&instruction, &env);
	Coroutine.start(&instruction, &env);

	// Both contexts halted, which is what a null program counter means.
	Coroutine.getContext(0).programCounter = null;
	Coroutine.getContext(1).programCounter = null;
	assert(Coroutine.done());

	assert(Coroutine.next(null, env.memory.ptr, &env, env.stackBottom) is null);

	Coroutine.clear();
}
