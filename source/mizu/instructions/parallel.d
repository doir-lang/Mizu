/**
* Threading, channel and mutex instructions.
*
* Two implementations live here, chosen at compile time:
*
* $(UL
*   $(LI By default, real OS threads, channels and read/write mutexes from $(LINK2 https://github.com/doir-lang/bc-threads, bc-threads).)
*   $(LI With the `MizuNoHardwareThreads` version set (implied on WASM), `mizu.opcode.Coroutine`'s round-robin scheduler.
*   There is only one real thread, so anything that would block instead rewinds the program counter by one and yields: the instruction simply runs again next time its context is scheduled.))
*/
module mizu.instructions.parallel;


static import fp.dynarray;
static import fp.pointer;

static import mizu.config;
static import mizu.error;
static import mizu.ffi.instructions;
import mizu.opcode;

static import bc.channel;
static import bc.thread;
static if (!mizu.config.noHardwareThreads) static import bc.mutex;

@nogc nothrow:

static if (!mizu.config.noHardwareThreads) {
	private alias Channel = bc.channel.Channel!ulong;

	// Payload handed to a freshly forked thread.
	private struct ThreadStart {
		Opcode* pc;
		RegistersAndStack env;
	}

	// The mutex a register names, or a fatal error if it names none.
	private bc.mutex.Mutex* mutexOf(ulong value) @trusted {
		auto mutex = cast(bc.mutex.Mutex*) value;
		if (mutex is null) mizu.error.fatal("Mutex does not exist.");
		return mutex;
	}

	// The channel a register names, or a fatal error if it names none.
	private Channel* channelOf(ulong value) @trusted {
		auto channel = cast(Channel*) value;
		if (channel is null) mizu.error.fatal("Channel does not exist.");
		return channel;
	}

	private extern(C) void* threadTrampoline(void* argument) @trusted {
		auto start = cast(ThreadStart*) argument;
		auto pc = start.pc;
		setupEnvironment(start.env, start.env.programStart, start.env.programEnd);
		auto result = pc.op(pc, start.env.memory.ptr, &start.env, start.env.stackBottom);
		fp.pointer.free(start);
		// The FFI type stack is thread local, so free it before this thread ends and it goes out of reach.
		mizu.ffi.instructions.releaseTypeStack();
		return result;
	}
} else {
	private alias Channel = bc.channel.LocalChannel!ulong;

	// The coroutine fallback's channel lives on one thread, resolved and refused as the threaded one is.
	private Channel* channelOf(ulong value) @trusted {
		auto channel = cast(Channel*) value;
		if (channel is null) mizu.error.fatal("Channel does not exist.");
		return channel;
	}
}

// Spawns a thread or coroutine context at `pc` with a copy of `env`'s memory, returning its thread handle or context index; failure is fatal.
private ulong newThread(Opcode* pc, RegistersAndStack* env, ubyte* sp) @trusted {
	static if (!mizu.config.noHardwareThreads) {
		// The thread outlives this frame, so its copy of our environment lives on the heap.
		auto start = fp.pointer.allocate!ThreadStart(1);
		if (start is null) mizu.error.fatal("Failed to allocate a thread environment.");
		start.pc = pc;
		fp.pointer.copy(start.env.memory[0 .. memorySize], env.memory[0 .. memorySize]);
		start.env.programStart = env.programStart;
		start.env.programEnd = env.programEnd;

		auto thread = fp.pointer.allocate!(bc.thread.Thread)(1);
		if (thread is null) mizu.error.fatal("Failed to allocate a thread handle.");
		auto created = bc.thread.create(&threadTrampoline, start);
		if (created.isNull) mizu.error.fatal("Failed to start a thread.");
		*thread = created.get;
		return cast(ulong) thread;
	} else {
		auto newEnv = fp.pointer.allocate!RegistersAndStack(1);
		if (newEnv is null) mizu.error.fatal("Failed to allocate a thread environment.");
		*newEnv = RegistersAndStack.init;
		fp.pointer.copy(newEnv.memory[0 .. memorySize], env.memory[0 .. memorySize]);
		setupEnvironment(*newEnv, env.programStart, env.programEnd);
		Coroutine.start(pc, newEnv);
		return fp.pointer.length(Coroutine.contexts) - 1;
	}
}

// Sleeps `microseconds`, true once served; the coroutine fallback instead records a deadline in `storageRegister` and rewinds `pc` until it passes.
pragma(inline, false) // Inlined clock reads would leave escaped locals that forbid the instruction's tail call.
private bool delay(ulong microseconds, ref Opcode* pc, ref ulong storageRegister) @trusted {
	static if (!mizu.config.noHardwareThreads) return bc.thread.sleep(microseconds);
	else {
		immutable now = bc.thread.monotonicMicroseconds();
		if (storageRegister == 0) {
			storageRegister = now == 0 ? 1 : now; // Zero means "not started yet".
			--pc;
			return false;
		}
		if (now - storageRegister < microseconds) {
			--pc;
			return false;
		}
		storageRegister = 0;
		return true;
	}
}

extern(C):

/**
* Forks a new thread whose program counter starts at an offset relative to this instruction.
* Zero starts it at this instruction, one at the next, and a negative offset at a previous one.
*
* The new thread gets its own copy of the current registers and stack.
* Failing to start it is fatal.
*
* Params:
*   out_ = register to store the thread reference in, for `joinThread`
*   a = register holding how many instructions away the thread starts (signed)
*
* Examples:
* ---
* static immutable Opcode[11] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 	Opcode(&channelCreate, Registers.t(1), Registers.t(0)),
* 	Opcode(&loadImmediate, Registers.t(2)).setImmediate(5),
* 	Opcode(&forkRelative, Registers.t(3), Registers.t(2)),
* 	Opcode(&channelReceive, Registers.t(4), Registers.t(1)),
* 	Opcode(&joinThread, 0, Registers.t(3)),
* 	Opcode(&channelClose, 0, Registers.t(1)),
* 	Opcode(&halt),
* 	// The forked thread starts here, sending 42 back.
* 	Opcode(&loadImmediate, Registers.t(5)).setImmediate(42),
* 	Opcode(&channelSend, 0, Registers.t(1), Registers.t(5)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(4)] == 42);
* ---
*/
void* forkRelative(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_", "a")(*pc), "mizu: a register index past registerCount");
	auto threadPC = pc + *cast(long*)&registers[pc.a];
	registers[pc.out_] = newThread(threadPC, env, sp);
	mixin(nextInstruction);
}

/**
* Forks a new thread whose program counter starts at an offset relative to this instruction, getting its own copy of the current registers and stack.
* Failing to start it is fatal.
*
* Params:
*   out_ = register to store the thread reference in, for `joinThread`
*   immediate = how many instructions away the thread starts, set with `setImmediateSigned`
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&forkRelativeImmediate, Registers.t(0)).setImmediateSigned(3),
* 	Opcode(&joinThread, 0, Registers.t(0)),
* 	Opcode(&halt),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 0);
* ---
*/
void* forkRelativeImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	auto threadPC = pc + immediateSigned(*pc);
	registers[pc.out_] = newThread(threadPC, env, sp);
	mixin(nextInstruction);
}

/**
* Forks a new thread with its program counter set to a value, usually the output of a `findLabel`, getting its own copy of the current registers and stack.
* Failing to start it is fatal.
*
* Params:
*   out_ = register to store the thread reference in, for `joinThread`
*   a = register holding the address of the instruction to start at
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&findLabel, Registers.t(0)).setImmediate(labelToImmediate("work")),
* 	Opcode(&forkTo, Registers.t(1), Registers.t(0)),
* 	Opcode(&joinThread, 0, Registers.t(1)),
* 	Opcode(&halt),
* 	Opcode(&label).setImmediate(labelToImmediate("work")),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* forkTo(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_", "a")(*pc), "mizu: a register index past registerCount");
	auto threadPC = cast(Opcode*) registers[pc.a];
	registers[pc.out_] = newThread(threadPC, env, sp);
	mixin(nextInstruction);
}

/**
* Waits for the provided thread to finish and releases its reference.
* Joining zero, the main thread, does nothing.
*
* With `MizuNoHardwareThreads`, an unfinished thread rewinds the program counter so this instruction runs again.
*
* Params:
*   a = register holding the thread to wait for, overwritten with `b` once it finishes
*   b = register holding the value to overwrite `a` with, usually `zero`
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&forkRelativeImmediate, Registers.t(0)).setImmediateSigned(3),
* 	Opcode(&joinThread, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 0);
* ---
*/
void* joinThread(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a", "b")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads) {
		auto thread = cast(bc.thread.Thread*) registers[pc.a];
		if (thread !is null) {
			bc.thread.join(*thread);
			fp.pointer.free(thread);
			registers[pc.a] = registers[pc.b];
		}
	} else {
		immutable contextId = cast(size_t) registers[pc.a];
		if (contextId) {
			if (!Coroutine.done(Coroutine.getContext(contextId)))
				--pc;
			else registers[pc.a] = registers[pc.b];
		}
	}
	mixin(nextInstruction);
}

/**
* Sleeps for the given number of microseconds; with `MizuNoHardwareThreads` it instead yields, rewinding the program counter, until they have passed.
*
* Params:
*   out_ = scratch register the coroutine fallback tracks the start of the sleep in; it holds zero once the sleep is over
*   a = register holding the number of microseconds to sleep
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(100),
* 	Opcode(&sleepMicroseconds, Registers.t(1), Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* sleepMicroseconds(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_", "a")(*pc), "mizu: a register index past registerCount");
	// A sleep the platform refused only ends early, which a program cannot tell from being descheduled late.
	cast(void) delay(registers[pc.a], pc, registers[pc.out_]);
	mixin(nextInstruction);
}

/**
* Creates an inter-thread communication channel, which can buffer a number of values or just one.
* Failing to allocate it is fatal.
*
* Channels send and receive register-sized binary blobs.
*
* Params:
*   out_ = register to store the channel reference in
*   a = register holding the capacity of the channel's buffer (zero means one item)
*
* Examples:
* ---
* static immutable Opcode[4] program = [
* 	Opcode(&loadImmediate, Registers.t(0)).setImmediate(4),
* 	Opcode(&channelCreate, Registers.t(1), Registers.t(0)),
* 	Opcode(&channelClose, 0, Registers.t(1)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* channelCreate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_", "a")(*pc), "mizu: a register index past registerCount");
	immutable requested = registers[pc.a] < 1 ? 1 : registers[pc.a];
	if (requested > size_t.max) mizu.error.fatal("Failed to allocate a channel.");
	immutable capacity = cast(size_t) requested;
	static if (!mizu.config.noHardwareThreads) auto channel = bc.channel.create!ulong(capacity);
	else auto channel = bc.channel.createLocal!ulong(capacity);
	if (channel is null) mizu.error.fatal("Failed to allocate a channel.");
	registers[pc.out_] = cast(size_t) channel;
	mixin(nextInstruction);
}

/**
* Closes the provided channel, freeing it, and releases its reference; no thread may use it afterward.
*
* Params:
*   a = register holding the channel to close, then overwritten with `b`
*   b = register holding the value to overwrite `a` with, usually `zero`
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&channelCreate, Registers.t(0), Registers.zero),
* 	Opcode(&channelClose, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 0);
* ---
*/
void* channelClose(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a", "b")(*pc), "mizu: a register index past registerCount");
	auto channel = channelOf(registers[pc.a]);
	bc.channel.close(channel);
	bc.channel.free(channel);
	registers[pc.a] = registers[pc.b];
	mixin(nextInstruction);
}

/**
* Blocks until there is an item to receive from the channel; with `MizuNoHardwareThreads` it instead yields, rewinding the program counter, until there is one.
*
* Params:
*   out_ = register to store the binary blob read from the channel in, or zero if the channel was closed while empty
*   a = register holding the channel to read from
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&channelCreate, Registers.t(0), Registers.zero),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(42),
* 	Opcode(&channelSend, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&channelReceive, Registers.t(2), Registers.t(0)),
* 	Opcode(&channelClose, 0, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
*/
void* channelReceive(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_", "a")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads) {
		auto received = bc.channel.receive(channelOf(registers[pc.a]));
		registers[pc.out_] = received.isNull ? 0 : received.get;
	} else {
		auto received = bc.channel.receive(channelOf(registers[pc.a]));
		if (received.isNull) --pc;
		else registers[pc.out_] = received.get;
	}
	mixin(nextInstruction);
}

/**
* Blocks until the channel has room for a new value, then sends it; with `MizuNoHardwareThreads` it instead yields, rewinding the program counter, until there is room.
* A value sent to a closed channel is dropped.
*
* Params:
*   a = register holding the channel to send to
*   b = register holding the binary blob to send
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&channelCreate, Registers.t(0), Registers.zero),
* 	Opcode(&loadImmediate, Registers.t(1)).setImmediate(42),
* 	Opcode(&channelSend, 0, Registers.t(0), Registers.t(1)),
* 	Opcode(&channelReceive, Registers.t(2), Registers.t(0)),
* 	Opcode(&channelClose, 0, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(2)] == 42);
* ---
*/
void* channelSend(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a", "b")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads)
		cast(void) bc.channel.send(channelOf(registers[pc.a]), registers[pc.b]);
	else {
		auto channel = channelOf(registers[pc.a]);
		// A full channel makes the sender wait its turn, as the threaded one blocks it; space was reserved at creation, so the send cannot fail.
		if (bc.channel.length(channel) >= bc.channel.capacity(channel)) --pc;
		else cast(void) bc.channel.send(channel, registers[pc.b]);
	}
	mixin(nextInstruction);
}

/**
* Creates a read/write lockable mutex.
* Failing to allocate it is fatal.
*
* Params:
*   out_ = register to store the mutex reference in
*
* Note: with `MizuNoHardwareThreads` there is no OS mutex; the register itself holds the lock state (0 unlocked, -1 write locked, n>0 read locked).
* Forking copies the registers, so each context holds its own lock rather than sharing one, and a contended blocking lock hangs.
* Use a channel to synchronise coroutine contexts.
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&mutexCreate, Registers.t(0)),
* 	Opcode(&mutexTryWriteLock, Registers.t(1), Registers.t(0)),
* 	Opcode(&mutexWriteUnlock, 0, Registers.t(0)),
* 	Opcode(&mutexFree, 0, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* mutexCreate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads) {
		// A `pthread_rwlock_t` binds to the address it was initialised at, so the heap mutex `create` returns cannot be copied.
		auto mutex = bc.mutex.create();
		if (mutex is null) mizu.error.fatal("Failed to allocate a mutex.");
		registers[pc.out_] = cast(size_t) mutex;
	} else
		registers[pc.out_] = 0;
	mixin(nextInstruction);
}

/**
* Frees a mutex, which no thread may hold.
*
* Params:
*   a = register holding the mutex to free, then overwritten with `b`
*   b = register holding the value to overwrite `a` with, usually `zero`
*
* Examples:
* ---
* static immutable Opcode[3] program = [
* 	Opcode(&mutexCreate, Registers.t(0)),
* 	Opcode(&mutexFree, 0, Registers.t(0), Registers.zero),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(0)] == 0);
* ---
*/
void* mutexFree(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a", "b")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads)
		bc.mutex.free(mutexOf(registers[pc.a]));
	registers[pc.a] = registers[pc.b];
	mixin(nextInstruction);
}

/**
* Blocks until an exclusive (writing) lock can be taken on the mutex; with `MizuNoHardwareThreads` it instead yields, rewinding the program counter.
*
* Params:
*   a = register holding the mutex to lock; with `MizuNoHardwareThreads`, the lock state, which this writes
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&mutexCreate, Registers.t(0)),
* 	Opcode(&mutexWriteLock, 0, Registers.t(0)),
* 	Opcode(&mutexTryReadLock, Registers.t(1), Registers.t(0)),
* 	Opcode(&mutexWriteUnlock, 0, Registers.t(0)),
* 	Opcode(&mutexFree, 0, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* mutexWriteLock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads)
		bc.mutex.lockForWriting(mutexOf(registers[pc.a]));
	else {
		if (registers[pc.a] != 0)
			--pc;
		else registers[pc.a] = ulong.max;
	}
	mixin(nextInstruction);
}

/**
* Attempts to take an exclusive (writing) lock on the mutex.
*
* Params:
*   out_ = register set to one if the lock was taken, zero otherwise
*   a = register holding the mutex to lock; with `MizuNoHardwareThreads`, the lock state, which this writes
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&mutexCreate, Registers.t(0)),
* 	Opcode(&mutexTryWriteLock, Registers.t(1), Registers.t(0)),
* 	Opcode(&mutexTryWriteLock, Registers.t(2), Registers.t(0)),
* 	Opcode(&mutexWriteUnlock, 0, Registers.t(0)),
* 	Opcode(&mutexFree, 0, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* assert(env.memory[Registers.t(2)] == 0);
* ---
*/
void* mutexTryWriteLock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_", "a")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads)
		registers[pc.out_] = bc.mutex.tryLockForWriting(mutexOf(registers[pc.a]));
	else {
		if (registers[pc.a] == 0) {
			registers[pc.a] = ulong.max;
			registers[pc.out_] = 1;
		} else registers[pc.out_] = 0;
	}
	mixin(nextInstruction);
}

/**
* Releases an exclusive (writing) lock so another thread can take it.
*
* Params:
*   a = register holding the mutex to unlock; with `MizuNoHardwareThreads`, the lock state, which this writes
*
* Examples:
* ---
* static immutable Opcode[7] program = [
* 	Opcode(&mutexCreate, Registers.t(0)),
* 	Opcode(&mutexWriteLock, 0, Registers.t(0)),
* 	Opcode(&mutexWriteUnlock, 0, Registers.t(0)),
* 	Opcode(&mutexTryWriteLock, Registers.t(1), Registers.t(0)),
* 	Opcode(&mutexWriteUnlock, 0, Registers.t(0)),
* 	Opcode(&mutexFree, 0, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* mutexWriteUnlock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads)
		bc.mutex.unlockForWriting(mutexOf(registers[pc.a]));
	else {
		if (registers[pc.a] == ulong.max)
			registers[pc.a] = 0;
	}
	mixin(nextInstruction);
}

/**
* Blocks until a shared (reading) lock can be taken on the mutex; with `MizuNoHardwareThreads` it instead yields, rewinding the program counter.
*
* Any number of threads may hold a reading lock at once, but only one may hold the writing lock.
*
* Params:
*   a = register holding the mutex to lock; with `MizuNoHardwareThreads`, the lock state, which this writes
*
* Examples:
* ---
* static immutable Opcode[6] program = [
* 	Opcode(&mutexCreate, Registers.t(0)),
* 	Opcode(&mutexReadLock, 0, Registers.t(0)),
* 	Opcode(&mutexTryWriteLock, Registers.t(1), Registers.t(0)),
* 	Opcode(&mutexReadUnlock, 0, Registers.t(0)),
* 	Opcode(&mutexFree, 0, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 0);
* ---
*/
void* mutexReadLock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads)
		bc.mutex.lockForReading(mutexOf(registers[pc.a]));
	else {
		if (*cast(long*)&registers[pc.a] < 0)
			--pc;
		else ++registers[pc.a];
	}
	mixin(nextInstruction);
}

/**
* Attempts to take a shared (reading) lock on the mutex.
*
* Params:
*   out_ = register set to one if the lock was taken, zero otherwise
*   a = register holding the mutex to lock; with `MizuNoHardwareThreads`, the lock state, which this writes
*
* Examples:
* ---
* static immutable Opcode[5] program = [
* 	Opcode(&mutexCreate, Registers.t(0)),
* 	Opcode(&mutexTryReadLock, Registers.t(1), Registers.t(0)),
* 	Opcode(&mutexReadUnlock, 0, Registers.t(0)),
* 	Opcode(&mutexFree, 0, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* mutexTryReadLock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("out_", "a")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads)
		registers[pc.out_] = bc.mutex.tryLockForReading(mutexOf(registers[pc.a]));
	else {
		if (*cast(long*)&registers[pc.a] >= 0) {
			++registers[pc.a];
			registers[pc.out_] = 1;
		} else registers[pc.out_] = 0;
	}
	mixin(nextInstruction);
}

/**
* Releases a shared (reading) lock so another thread can take it.
*
* Params:
*   a = register holding the mutex to unlock; with `MizuNoHardwareThreads`, the lock state, which this writes
*
* Examples:
* ---
* static immutable Opcode[7] program = [
* 	Opcode(&mutexCreate, Registers.t(0)),
* 	Opcode(&mutexReadLock, 0, Registers.t(0)),
* 	Opcode(&mutexReadUnlock, 0, Registers.t(0)),
* 	Opcode(&mutexTryWriteLock, Registers.t(1), Registers.t(0)),
* 	Opcode(&mutexWriteUnlock, 0, Registers.t(0)),
* 	Opcode(&mutexFree, 0, Registers.t(0)),
* 	Opcode(&halt),
* ];
* RegistersAndStack env;
* setupEnvironment(env, program[]);
* cast(void) startFromEnvironment(program[], env);
* assert(env.memory[Registers.t(1)] == 1);
* ---
*/
void* mutexReadUnlock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	assert(mizu.opcode.registersValid!("a")(*pc), "mizu: a register index past registerCount");
	static if (!mizu.config.noHardwareThreads)
		bc.mutex.unlockForReading(mutexOf(registers[pc.a]));
	else {
		if (*cast(long*)&registers[pc.a] > 0)
			--registers[pc.a];
	}
	mixin(nextInstruction);
}

