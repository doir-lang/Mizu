/**
* The core Mizu types: the register file, the `Opcode` an instruction acts on, the environment holding a program's registers and stack, and the dispatch mixin (`mizuNext`) every instruction ends with.
*/
module mizu.opcode;

import core.stdc.string : memcpy;

static import fp.dynarray;
static import fp.pointer;

static import mizu.config;
static import mizu.error;

// DMD performs no tail calls, so dispatch overflows the stack; `MizuAllowDMD` lets analysis-only tools such as `dmd -o-` and ddoc through.
version(DigitalMars) {
	static if (mizu.config.allowDMD)
		pragma(msg, "mizu: warning - DMD does not perform tail call optimization, so Mizu's dispatch will overflow the stack at run time.");
	else
		static assert(0, "mizu: DMD cannot build Mizu. It performs no tail call optimization, so the dispatch below overflows the stack on the first loop of any size, and it emits druntime calls that -betterC then refuses to link. Build with LDC (--compiler=ldc2) at -O1 or higher. To analyse these sources with DMD without running them, set -version=MizuAllowDMD.");
}

@nogc nothrow:

/// Type used to name a register inside an `Opcode`.
alias Reg = ushort;

/// How many registers an environment has; the stack begins where they end.
enum size_t registerCount = 256;

/// How many temporary registers (`t0` up to `t19`) there are.
enum size_t temporaryCount = 20;

/// How many argument registers (`a0` onward) there are: every register after `ra`.
enum size_t argumentCount = registerCount - temporaryCount - 2;

/**
* The register file.
*
* $(UL
*   $(LI `x0` (`zero`) is always zero.)
*   $(LI `x1`-`x20` (`t0`-`t19`) are temporaries, saved by the caller if needed.)
*   $(LI `x21` (`ra`) is the return address (callee saved).)
*   $(LI `x22`-`x255` (`a0`-`a233`) are the argument registers (callee saved).))
*
* Note: `a0`/`x22` and `a1`/`x23` are the canonical return registers.
*
* A `struct` used purely as a namespace, mirroring the C++ `mizu::registers` namespace, so call sites read `Registers.t(0)`.
*/
struct Registers {
	@disable this();
static @nogc nothrow:

	/**
	* Generic register lookup; `i` is the register's index, below `registerCount`.
	*
	* Examples:
	* ---
	* static assert(Registers.x(7) == 7);
	* ---
	*/
	Reg x(size_t i) in(i < registerCount) { return cast(Reg) i; }

	/**
	* Temporary register lookup; `i` is the temporary's index, below `temporaryCount`.
	*
	* Examples:
	* ---
	* static assert(Registers.t(0) == 1);
	* static assert(Registers.t(19) == 20);
	* ---
	*/
	Reg t(size_t i) in(i < temporaryCount) { return cast(Reg)(i + 1); }

	/**
	* Argument register lookup; `i` is the argument's index, below `argumentCount`.
	*
	* Examples:
	* ---
	* static assert(Registers.a(0) == 22);
	* ---
	*/
	Reg a(size_t i) in(i < argumentCount) { return cast(Reg)(returnAddress + 1 + i); }

	/// The always-zero register.
	enum Reg zero = 0;
	/// The return address register.
	enum Reg returnAddress = temporaryCount + 1;
	/// Ditto
	alias ra = returnAddress;
}

/**
* Spelling of `Registers` that matches the C++ `mizu::registers` namespace.
*
* Note: inside an instruction the `registers` parameter shadows this alias, so instruction bodies say `Registers.a(0)`.
*/
alias registers = Registers;

/**
* The interface every instruction implements.
*
* `extern(C)` is not cosmetic: every instruction tail-calls the next one through this pointer, and a tail call is only possible between functions that agree on their calling convention.
*/
alias Instruction = extern(C) void* function(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @nogc nothrow;

/**
* An instruction plus (up to) three registers for it to act upon.
*
* Note: since `Instruction` is a pointer this struct has different sizes on different machines, so Mizu binaries are only compatible with machines of the same pointer size and endianness.
*
* The immediate accessors pack a 32 bit value into the `a`/`b` register fields as `a = low half, b = high half`. Writing the halves explicitly, rather than reinterpreting the pair as one `uint`, lets them constant-fold and keeps the packing independent of host endianness, so whole programs can live in read-only data.
*/
struct Opcode {
	/// Instruction to perform.
	Instruction op;
	/// Register to store the instruction's result in.
	Reg out_;
	/// Register storing the first argument.
	Reg a;
	/// Register storing the second argument.
	Reg b;
}

/**
* The `u32` immediate held in `code.a` and `code.b`.
*
* Examples:
* ---
* static assert(Opcode.init.setImmediate(0xDEADBEEF).immediate == 0xDEADBEEF);
* ---
*/
uint immediate(const Opcode code) { return code.a | (cast(uint) code.b << 16); }

/**
* `code` with `a` and `b` replaced by a `u32` immediate value: the low half in `a`, the high half in `b`.
*
* Examples:
* ---
* static immutable Opcode code = Opcode(&loadImmediate, Registers.t(0)).setImmediate(0xDEADBEEF);
* static assert(code.a == 0xBEEF && code.b == 0xDEAD);
* ---
*/
Opcode setImmediate(Opcode code, uint value) {
	code.a = cast(Reg)(value & 0xFFFF);
	code.b = cast(Reg)(value >> 16);
	return code;
}

/**
* The `i32` immediate held in `code.a` and `code.b`.
*
* Examples:
* ---
* static assert(Opcode.init.setImmediateSigned(-1).immediateSigned == -1);
* ---
*/
int immediateSigned(const Opcode code) { return cast(int) immediate(code); }

/**
* `code` with `a` and `b` replaced by an `i32` immediate value.
*
* Examples:
* ---
* static assert(Opcode.init.setImmediateSigned(int.min).immediateSigned == int.min);
* ---
*/
Opcode setImmediateSigned(Opcode code, int value) { return setImmediate(code, cast(uint) value); }

/**
* The `i16` immediate held in `code.b`, used for branch offsets.
*
* Examples:
* ---
* static assert(Opcode.init.setBranchImmediate(-2).branchImmediate == -2);
* ---
*/
short branchImmediate(const Opcode code) { return cast(short) code.b; }

/**
* `code` with `b` replaced by an `i16` immediate value, used for branch offsets.
*
* Examples:
* ---
* static immutable Opcode code = Opcode(&branchRelativeImmediate, 0, Registers.t(0)).setBranchImmediate(-1);
* static assert(code.a == Registers.t(0) && code.branchImmediate == -1);
* ---
*/
Opcode setBranchImmediate(Opcode code, short value) {
	code.b = cast(Reg) value;
	return code;
}

/**
* The `f32` immediate held in `code.a` and `code.b`.
*
* Examples:
* ---
* static assert(Opcode.init.setImmediateF32(1.5f).immediateF32 == 1.5f);
* ---
*/
float immediateF32(const Opcode code) {
	immutable bits = immediate(code);
	return *cast(const float*) &bits;
}

/**
* `code` with `a` and `b` replaced by an `f32` immediate value.
*
* Examples:
* ---
* static assert(Opcode.init.setImmediateF32(-0.125f).immediateF32 == -0.125f);
* ---
*/
Opcode setImmediateF32(Opcode code, float value) { return setImmediate(code, *cast(uint*) &value); }

/**
* `code` with `a` and `b` replaced by the lower half of an `f64` immediate value; pair it with `setUpperImmediateF64`.
*
* Examples:
* ---
* enum double value = 1234.5678;
* immutable ulong bits = Opcode.init.setLowerImmediateF64(value).immediate | (cast(ulong) Opcode.init.setUpperImmediateF64(value).immediate << 32);
* assert(*cast(const double*) &bits == value);
* ---
*/
Opcode setLowerImmediateF64(Opcode code, double value) {
	return setImmediate(code, cast(uint)(*cast(ulong*) &value));
}

/**
* `code` with `a` and `b` replaced by the upper half of an `f64` immediate value; pair it with `setLowerImmediateF64`.
*
* Examples:
* ---
* static assert(Opcode.init.setUpperImmediateF64(-2.0).immediate == 0xC000_0000);
* ---
*/
Opcode setUpperImmediateF64(Opcode code, double value) {
	return setImmediate(code, cast(uint)((*cast(ulong*) &value) >> 32));
}

/**
* `code` with `a` and `b` replaced by the lower half of a host pointer; pair it with `setHostPointerUpperImmediate`.
*
* Examples:
* ---
* static int target;
* auto code = Opcode.init.setHostPointerLowerImmediate(&target);
* assert(code.immediate == cast(uint) cast(size_t) &target);
* ---
*/
Opcode setHostPointerLowerImmediate(Opcode code, const(void)* ptr) {
	return setImmediate(code, cast(uint) cast(size_t) ptr);
}

/**
* `code` with `a` and `b` replaced by the upper half of a host pointer, or zero where pointers are 32 bits; pair it with `setHostPointerLowerImmediate`.
*
* Examples:
* ---
* static int target;
* auto code = Opcode.init.setHostPointerUpperImmediate(&target);
* assert((cast(ulong) code.immediate << 32 | Opcode.init.setHostPointerLowerImmediate(&target).immediate) == cast(size_t) &target);
* ---
*/
Opcode setHostPointerUpperImmediate(Opcode code, const(void)* ptr) {
	static if (size_t.sizeof > uint.sizeof)
		return setImmediate(code, cast(uint)((cast(size_t) ptr) >> 32));
	else
		return setImmediate(code, 0);
}

/**
* How many registers long a Mizu environment's memory space is.
* See_Also: `mizu.config.stackSizeKilobytes`
*/
enum size_t memorySize = cast(size_t)(1024 * mizu.config.stackSizeKilobytes) / ulong.sizeof;
/// How many bytes a Mizu environment's memory space is.
enum size_t memorySizeBytes = memorySize * ulong.sizeof;
/// How many bytes of a Mizu environment's memory space are stack rather than registers.
enum size_t stackSizeBytes = (memorySize - registerCount) * ulong.sizeof;
static assert(memorySize > registerCount, "mizu: stackSizeKilobytes leaves no room for a stack");

/// The registers and stack space backing one Mizu program or thread.
struct RegistersAndStack {
	/**
	* Memory holding both the registers and the stack.
	* See_Also: `mizu.config.stackSizeKilobytes`
	*/
	fp.pointer.Array!(ulong, memorySize) memory;
	/// Boundary between the stack and the registers.
	ubyte* stackBoundary;
	/**
	* The bottom (one past the last byte) of the stack.
	*
	* Note: Mizu's stack pointer counts down from the end of `memory` until it reaches `stackBoundary`.
	*/
	ubyte* stackBottom;

	/// Start of the program, or null if unknown.
	const(Opcode)* programStart = null;
	/// End of the program, or null if unknown.
	const(Opcode)* programEnd = null;
}

/**
* Where the program `env` runs starts, estimated as `maximumLabelSearch` instructions before `pc` when unknown.
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* RegistersAndStack env;
* assert(calculateProgramStart(env, program.ptr) is program.ptr - maximumLabelSearch);
* setupEnvironment(env, program[]);
* assert(calculateProgramStart(env, program.ptr) is program.ptr);
* ---
*/
const(Opcode)* calculateProgramStart(ref const RegistersAndStack env, const(Opcode)* pc) {
	return env.programStart ? env.programStart : pc - mizu.config.maximumLabelSearch;
}

/**
* Where the program `env` runs ends, estimated as `maximumLabelSearch` instructions after `pc` when unknown.
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* assert(calculateProgramEnd(env, program.ptr) is program.ptr + 1);
* ---
*/
const(Opcode)* calculateProgramEnd(ref const RegistersAndStack env, const(Opcode)* pc) {
	return env.programEnd ? env.programEnd : pc + mizu.config.maximumLabelSearch;
}

/**
* Configures a new Mizu environment, zeroing register `x0`.
*
* Params:
*   env = the environment to configure
*   programStart = pointer to the start of the program (optional)
*   programEnd = pointer to one past the end of the program (optional)
*
* Examples:
* ---
* RegistersAndStack env;
* setupEnvironment(env);
* assert(env.memory[0] == 0);
* assert(env.stackBottom - env.stackBoundary == stackSizeBytes);
* ---
*/
void setupEnvironment(ref RegistersAndStack env, const(Opcode)* programStart = null, const(Opcode)* programEnd = null) @trusted {
	env.memory[0] = 0;
	env.stackBoundary = cast(ubyte*)(env.memory.ptr + registerCount);
	env.stackBottom = cast(ubyte*)(env.memory.ptr + memorySize);
	env.programStart = programStart;
	env.programEnd = programEnd;
}

/**
* Configures a new Mizu environment to run `program`, zeroing register `x0`.
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* assert(env.programStart == program.ptr);
* assert(env.programEnd == program.ptr + 1);
* ---
*/
void setupEnvironment(ref RegistersAndStack env, const(Opcode)[] program) @trusted {
	setupEnvironment(env, program.ptr, program.ptr + program.length);
}

/**
* Copies `binary` into the bottom of an environment's stack.
*
* Data longer than `stackSizeBytes` runs on into the registers, so a whole `memory` snapshot, as `mizu.portable_format.toPortable` takes, restores them too.
*
* Params:
*   env = the environment to copy data into
*   binary = the data to fill the bottom of its stack with, at most `memorySizeBytes` long
*
* Examples:
* ---
* static immutable ubyte[4] data = [0xDE, 0xAD, 0xBE, 0xEF];
* RegistersAndStack env;
* setupEnvironment(env);
* fillStackBottom(env, data[]);
* assert((env.stackBottom - 4)[0 .. 4] == data[]);
* ---
*/
void fillStackBottom(ref RegistersAndStack env, const(void)[] binary) @trusted {
	assert(binary.length <= memorySizeBytes, "mizu: data does not fit in memory");
	auto end = cast(ubyte*)(env.memory.ptr + memorySize);
	memcpy(end - binary.length, binary.ptr, binary.length);
}

/**
* Prints one instruction's name and operands to stdout, but only when the `MizuEnableTracing` version is set.
*
* Examples:
* ---
* static immutable Opcode code = Opcode(&halt);
* trace("halt", &code);
* ---
*/
void trace(scope const(char)[] name, const(Opcode)* pc) @trusted {
	static if (mizu.config.enableTracing) {
		import core.stdc.stdio : printf;
		cast(void) printf("%.*s(%u, %u, %u)\n", cast(int) name.length, name.ptr, pc.out_, pc.a, pc.b);
	}
}

/**
* Executes the next instruction. Mix this in at the end of every instruction: `mixin(mizuNext);`
*
* It is a mixin rather than a function because the dispatch must be a tail call made by the instruction itself; see the tail call notes in the README.
*
* Examples:
* ---
* static extern(C) void* nop(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @nogc nothrow {
* 	mixin(mizuNext);
* }
* static immutable Opcode[2] program = [Opcode(&nop), Opcode(&halt)];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* assert(startFromEnvironment(program[], env) is null);
* ---
*/
enum string mizuNext = mizu.config.noHardwareThreads
	? q{
		{
			mizu.opcode.trace(__FUNCTION__, pc);
			registers[0] = 0;
			return mizu.opcode.Coroutine.next(pc, registers, env, sp);
		}
	}
	: q{
		{
			mizu.opcode.trace(__FUNCTION__, pc);
			registers[0] = 0;
			++pc;
			return pc.op(pc, registers, env, sp);
		}
	};

static if (!mizu.config.noHardwareThreads) {

	/**
	* Starts executing `program` in `env`.
	*
	* Returns: whatever the program's final instruction returned (null for `halt`).
	*
	* Examples:
	* ---
	* static immutable Opcode[2] program = [
	* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
	* 	Opcode(&halt),
	* ];
	* RegistersAndStack env;
	* setupEnvironment(env, program[]);
	* assert(startFromEnvironment(program.ptr, env) is null);
	* assert(env.memory[Registers.t(0)] == 42);
	* ---
	*/
	void* startFromEnvironment(const(Opcode)* program, ref RegistersAndStack env) @trusted {
		auto pc = cast(Opcode*) program;
		return pc.op(pc, env.memory.ptr, &env, env.stackBottom);
	}

} else {

	/**
	* The single-core fallback for `mizu.instructions.parallel`: instead of OS threads, every "thread" is an execution context and `next` round-robins between them, so an instruction that cannot make progress yet just rewinds its own program counter and yields.
	*/
	struct Coroutine {
		/// One suspended (or running) Mizu thread.
		static struct ExecutionContext {
			/// The instruction this context last ran; null marks a context that has run to completion.
			Opcode* programCounter;
			/// The context's stack pointer while it is suspended.
			ubyte* stackPointer;
			/// The registers and stack this context runs in.
			RegistersAndStack* environment;
		}

		/// All live contexts, as an `fp.dynarray`.
		__gshared ExecutionContext* contexts = null;
		/// Index of the context currently executing.
		__gshared size_t currentContext = 0;

	static @nogc nothrow:

		/**
		* True once `context` has halted.
		*
		* Examples:
		* ---
		* static if (noHardwareThreads) {
		* 	Coroutine.ExecutionContext finished;
		* 	assert(Coroutine.done(finished));
		* }
		* ---
		*/
		bool done(ref const ExecutionContext context) { return context.programCounter is null; }

		/**
		* Advances `currentContext` to the next context, wrapping around, and returns it.
		*
		* Examples:
		* ---
		* static if (noHardwareThreads) {
		* 	static immutable Opcode[1] program = [Opcode(&halt)];
		* 	RegistersAndStack env;
		* 	setupEnvironment(env, program[]);
		* 	Coroutine.start(cast(Opcode*) program.ptr, &env);
		* 	Coroutine.start(cast(Opcode*) program.ptr, &env);
		* 	assert(Coroutine.nextContext() == 1);
		* 	assert(Coroutine.nextContext() == 0);
		* 	Coroutine.clear();
		* }
		* ---
		*/
		size_t nextContext() {
			return currentContext = (currentContext + 1) % fp.pointer.length(contexts);
		}

		/**
		* The context at `index`, which must be below the number of contexts.
		*
		* Examples:
		* ---
		* static if (noHardwareThreads) {
		* 	static immutable Opcode[1] program = [Opcode(&halt)];
		* 	RegistersAndStack env;
		* 	setupEnvironment(env, program[]);
		* 	Coroutine.start(cast(Opcode*) program.ptr, &env);
		* 	assert(Coroutine.getContext(0).environment is &env);
		* 	Coroutine.clear();
		* }
		* ---
		*/
		ref ExecutionContext getContext(size_t index) @trusted
		in(index < fp.pointer.length(contexts))
		{
			return contexts[index];
		}

		/**
		* The context currently executing.
		*
		* Examples:
		* ---
		* static if (noHardwareThreads) {
		* 	static immutable Opcode[1] program = [Opcode(&halt)];
		* 	RegistersAndStack env;
		* 	setupEnvironment(env, program[]);
		* 	Coroutine.start(cast(Opcode*) program.ptr, &env);
		* 	assert(&Coroutine.getCurrentContext() is &Coroutine.getContext(0));
		* 	Coroutine.clear();
		* }
		* ---
		*/
		ref ExecutionContext getCurrentContext() { return getContext(currentContext); }

		/**
		* Suspends the running context and resumes the next one that still has work to do, returning null once every context has halted.
		*
		* Note: shares `Instruction`'s signature so instructions can tail-call it.
		*
		* Examples:
		* ---
		* static if (noHardwareThreads) {
		* 	static immutable Opcode[2] program = [Opcode(&label), Opcode(&halt)];
		* 	RegistersAndStack env;
		* 	setupEnvironment(env, program[]);
		* 	Coroutine.start(cast(Opcode*) program.ptr, &env);
		* 	auto context = &Coroutine.getCurrentContext();
		* 	assert(Coroutine.next(context.programCounter, env.memory.ptr, &env, env.stackBottom) is null);
		* 	Coroutine.clear();
		* }
		* ---
		*/
		extern(C) void* next(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) @trusted {
			assert(sp);
			getCurrentContext().stackPointer = sp;

			if (fp.pointer.length(contexts) == 1) {
				getCurrentContext().programCounter = ++pc;
				return pc.op(pc, registers, env, sp);
			}
			// Record pc updates (jumps) before switching away.
			getCurrentContext().programCounter = pc;

			// A loop rather than recursion, so a list of finished contexts terminates instead of overflowing the stack.
			immutable start = currentContext;
			do {
				auto index = nextContext();
				auto context = &getContext(index);
				if (context.programCounter is null) continue;

				pc = ++context.programCounter;
				return pc.op(pc, context.environment.memory.ptr, context.environment, context.stackPointer);
			} while (currentContext != start);

			return null;
		}

		/**
		* Registers a new context beginning at `programCounter`, calling `mizu.error.fatal` if it cannot be stored.
		*
		* Examples:
		* ---
		* static if (noHardwareThreads) {
		* 	static immutable Opcode[1] program = [Opcode(&halt)];
		* 	RegistersAndStack env;
		* 	setupEnvironment(env, program[]);
		* 	Coroutine.start(cast(Opcode*) program.ptr, &env);
		* 	assert(!Coroutine.done());
		* 	Coroutine.clear();
		* }
		* ---
		*/
		void start(Opcode* programCounter, RegistersAndStack* environment) @trusted {
			assert(programCounter && environment);
			if (!fp.dynarray.pushBack(contexts, ExecutionContext(programCounter - 1, environment.stackBottom, environment)))
				mizu.error.fatal("Failed to allocate an execution context.");
		}

		/**
		* Releases every context.
		*
		* Examples:
		* ---
		* static if (noHardwareThreads) {
		* 	Coroutine.clear();
		* 	assert(Coroutine.contexts is null);
		* }
		* ---
		*/
		void clear() @trusted {
			fp.dynarray.free(contexts);
			currentContext = 0;
		}

		/**
		* True once every context has halted, including when there are none.
		*
		* Examples:
		* ---
		* static if (noHardwareThreads) assert(Coroutine.done());
		* ---
		*/
		bool done() @trusted {
			foreach (i; 0 .. fp.pointer.length(contexts))
				if (!done(getContext(i)))
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
			result = Coroutine.next(context.programCounter, context.environment.memory.ptr, context.environment, context.stackPointer);
		} while (result is null && !Coroutine.done());

		Coroutine.clear();
		return result;
	}

}

/**
* Starts executing `program` in `env`, taking the whole program as a slice.
*
* Returns: whatever the program's final instruction returned (null for `halt`).
*
* Examples:
* ---
* static immutable Opcode[1] program = [Opcode(&halt)];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* assert(startFromEnvironment(program[], env) is null);
* ---
*/
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
	static assert(Registers.a(argumentCount - 1) == registerCount - 1);
	static assert(Registers.x(7) == 7);

	// Each accessor refuses an index past its own range: t(20) would alias ra, and a(argumentCount) the stack.
	static assert(!__traits(compiles, { enum r = Registers.t(temporaryCount); }));
	static assert(!__traits(compiles, { enum r = Registers.a(argumentCount); }));
	static assert(!__traits(compiles, { enum r = Registers.x(registerCount); }));
}

unittest {
	// Immediates pack into the a/b register pair and read back unchanged at compile time, so programs can live in read-only data.
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

	// An f64 immediate takes two instructions, so check the halves recombine.
	enum double value = 1234.5678;
	enum Opcode lower = Opcode.init.setLowerImmediateF64(value);
	enum Opcode upper = Opcode.init.setUpperImmediateF64(value);

	immutable ulong bits = lower.immediate | (cast(ulong) upper.immediate << 32);
	assert(*cast(const double*)&bits == value);
}

unittest {
	// The same packing at run time; `__gshared` inputs keep the optimizer from folding the calls back into CTFE.
	__gshared uint immediate = 0xDEADBEEF;
	__gshared int signed = int.min;
	__gshared short branch = -2;
	__gshared float single = 1.5f;
	__gshared double dbl = 1234.5678;
	__gshared size_t index = 7;

	auto code = Opcode.init.setImmediate(immediate);
	assert(code.immediate == 0xDEADBEEF);
	assert(code.a == 0xBEEF);
	assert(code.b == 0xDEAD);

	assert(Opcode.init.setImmediateSigned(signed).immediateSigned == int.min);
	assert(Opcode.init.setBranchImmediate(branch).branchImmediate == -2);
	assert(Opcode.init.setImmediateF32(single).immediateF32 == 1.5f);

	immutable lower = Opcode.init.setLowerImmediateF64(dbl);
	immutable upper = Opcode.init.setUpperImmediateF64(dbl);
	immutable ulong bits = lower.immediate | (cast(ulong) upper.immediate << 32);
	assert(*cast(const double*)&bits == dbl);

	assert(Registers.x(index) == 7);
}

unittest {
	// setupEnvironment lays out the memory space the way the instructions expect.
	static immutable Opcode[2] program = [Opcode.init, Opcode.init];

	RegistersAndStack env;
	setupEnvironment(env, program[]);

	assert(env.memory[0] == 0);
	assert(env.stackBoundary is cast(ubyte*)(env.memory.ptr + registerCount));
	assert(env.stackBottom is cast(ubyte*)(env.memory.ptr + memorySize));
	assert(env.stackBottom - env.stackBoundary == stackSizeBytes);
	assert(env.programStart is program.ptr);
	assert(env.programEnd is program.ptr + 2);

	// And with no program given, the label search bounds straddle the pc.
	RegistersAndStack bare;
	setupEnvironment(bare);
	auto pc = cast(const(Opcode)*) program.ptr;
	assert(calculateProgramStart(bare, pc) is pc - mizu.config.maximumLabelSearch);
	assert(calculateProgramEnd(bare, pc) is pc + mizu.config.maximumLabelSearch);
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

	// A whole snapshot of memory lands on the registers as well.
	__gshared ulong[memorySize] snapshot;
	snapshot[3] = 7;
	fillStackBottom(env, snapshot[]);
	assert(env.memory[3] == 7);
}

static if (mizu.config.noHardwareThreads)
unittest {
	// `startFromEnvironment` checks `done()` before scheduling again, so an all-finished context list is only reachable by driving `next` directly.
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
