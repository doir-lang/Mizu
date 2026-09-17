/**
* Threading, channel and mutex instructions.
*
* Two implementations live here, chosen at compile time:
*
* $(UL
*   $(LI By default, real OS threads, channels and read/write mutexes from
*        $(LINK2 https://github.com/doir-lang/bc-threads, bc-threads).)
*   $(LI With the `MizuNoHardwareThreads` version set (implied on WASM),
*        `mizu.opcode.Coroutine`'s round-robin scheduler. There is only one
*        real thread, so anything that would block instead rewinds the
*        program counter by one and yields — the instruction simply runs
*        again next time its context is scheduled.))
*/
module mizu.instructions.parallel;

import core.stdc.string : memcpy;

import fp.pointer : fpMalloc = malloc, fpFree = free;

import mizu.config : noHardwareThreads;
import mizu.exception : fatal;
import mizu.opcode;

@nogc nothrow:

static if (!noHardwareThreads) {
	import bc.channel : BcChannel = Channel;
	import bc.mutex : BcMutex = Mutex;
	import bc.thread : BcThread = Thread;

	private alias Channel = BcChannel!ulong;

	/// Payload handed to a freshly forked thread.
	private struct ThreadStart {
		Opcode* pc;
		RegistersAndStack env;
	}

	private extern(C) void* threadTrampoline(void* argument) @trusted {
		import mizu.ffi.instructions : releaseTypeStack;

		auto start = cast(ThreadStart*) argument;
		auto pc = start.pc;
		setupEnvironment(start.env, start.env.programStart, start.env.programEnd);
		auto result = pc.op(pc, start.env.memory.ptr, &start.env, start.env.stackBottom);
		fpFree(start);
		// The FFI type stack is thread local, so this thread's copy goes out of
		// reach the moment this function returns; free it while it still can be.
		releaseTypeStack();
		return result;
	}
}

/**
* Spawns a new thread (or coroutine context) beginning at `pc`, giving it a
* copy of the current environment's memory.
*
* Note: not an instruction; the `fork*` instructions call it.
*
* Returns:
*   With hardware threads, a pointer to the new thread's handle. With the
*   coroutine fallback, the index of the new context.
*/
ulong newThread(Opcode* pc, RegistersAndStack* env, ubyte* sp) @trusted {
	static if (!noHardwareThreads) {
		// The thread outlives this frame, so its environment (a copy of ours,
		// so the new thread starts with the same register values) has to live
		// on the heap rather than on our stack.
		auto start = fpMalloc!ThreadStart(1);
		if (start is null) fatal("Failed to allocate a thread environment.");
		start.pc = pc;
		memcpy(start.env.memory.ptr, env.memory.ptr, memorySizeBytes);
		start.env.programStart = env.programStart;
		start.env.programEnd = env.programEnd;

		auto thread = fpMalloc!BcThread(1);
		if (thread is null) fatal("Failed to allocate a thread handle.");
		import bc.thread : threadCreate = create;
		*thread = threadCreate(&threadTrampoline, start);
		return cast(ulong) thread;
	} else {
		import fp.dynarray : length;
		auto newEnv = fpMalloc!RegistersAndStack(1);
		if (newEnv is null) fatal("Failed to allocate a thread environment.");
		*newEnv = RegistersAndStack.init;
		memcpy(newEnv.memory.ptr, env.memory.ptr, memorySizeBytes);
		setupEnvironment(*newEnv, env.programStart, env.programEnd);
		Coroutine.start(pc, newEnv);
		return length(Coroutine.contexts) - 1; // Index of the new context.
	}
}

/**
* Sleeps for `microseconds`.
*
* With hardware threads this really sleeps the calling thread. With the
* coroutine fallback it cannot — blocking would stall every other context —
* so it records a deadline in `storageRegister` and rewinds `pc` until the
* deadline passes.
*
* Note:
*   Kept out of line deliberately. Every platform's clock reads through a
*   pointer to a local (`timespec`, `LARGE_INTEGER`), and inlining those into
*   `sleepMicroseconds` would give it a stack frame holding objects whose
*   addresses escaped — from which the target refuses a tail call, so the
*   dispatch at the end of the instruction would become an ordinary call. The
*   coroutine fallback reaches that dispatch once per yield while it waits,
*   which is a loop rather than a stack of frames only as long as the tail
*   call survives.
*
* Returns: true once the delay has elapsed, false if it has not (the coroutine
*          fallback before its deadline, or a sleep the platform refused).
*/
pragma(inline, false)
bool delay(ulong microseconds, ref Opcode* pc, ref ulong storageRegister) @trusted {
	static if (!noHardwareThreads) {
		version(Posix) {
			import core.stdc.errno : errno, EINTR;
			import core.sys.posix.time : nanosleep, timespec;

			timespec request = {
				tv_sec: cast(typeof(timespec.tv_sec))(microseconds / 1_000_000),
				tv_nsec: cast(typeof(timespec.tv_nsec))((microseconds % 1_000_000) * 1_000)
			};
			// A signal cuts the sleep short and reports how much was left, so
			// go back to sleep for the remainder. Only `EINTR` writes
			// `remaining`, so any other failure has to break out rather than
			// feed an untouched (on the first pass, uninitialised) buffer back
			// in and spin forever.
			timespec remaining;
			while (nanosleep(&request, &remaining) != 0) {
				if (errno != EINTR) return false;
				request = remaining;
			}
		} else version(Windows) {
			import core.sys.windows.windows : Sleep;
			Sleep(cast(uint)((microseconds + 999) / 1000));
		}
		return true;
	} else {
		immutable now = monotonicMicroseconds();
		if (storageRegister == 0) {
			storageRegister = now == 0 ? 1 : now; // Zero means "not started yet".
			--pc; // Yield and come back.
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

// druntime binds neither `clock_gettime` nor `CLOCK_MONOTONIC` on macOS,
// though libSystem has exported the function since 10.12 and `<time.h>`
// spells the clock 6, so bind them rather than give the platform a worse
// clock than it has. This has to sit at module scope: `extern(C)` on a
// declaration nested inside a function body does not reach the mangling.
version(OSX) {
	import core.sys.posix.time : timespec;
	private extern(C) @nogc nothrow int clock_gettime(int, timespec*);
	private alias darwinClockGettime = clock_gettime;
	private enum int darwinClockMonotonic = 6;
}

/// Microseconds from an arbitrary monotonic origin.
private ulong monotonicMicroseconds() @trusted {
	version(Posix) {
		version(OSX) {
			import core.sys.posix.time : timespec;
			alias CLOCK_MONOTONIC = darwinClockMonotonic;
			alias clock_gettime = darwinClockGettime;
		} else
			import core.sys.posix.time : clock_gettime, timespec, CLOCK_MONOTONIC;

		timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		return cast(ulong) now.tv_sec * 1_000_000 + cast(ulong) now.tv_nsec / 1_000;
	} else version(Windows) {
		import core.sys.windows.windows : QueryPerformanceCounter, QueryPerformanceFrequency, LARGE_INTEGER;
		LARGE_INTEGER counter, frequency;
		QueryPerformanceCounter(&counter);
		QueryPerformanceFrequency(&frequency);
		return cast(ulong)(counter.QuadPart * 1_000_000 / frequency.QuadPart);
	} else {
		import core.stdc.time : clock, CLOCKS_PER_SEC;
		return cast(ulong) clock() * 1_000_000 / CLOCKS_PER_SEC;
	}
}

extern(C):

/**
* Forks a new thread whose program counter starts at an offset relative to
* this instruction. Zero starts it at this instruction, one at the next, and
* a negative offset at a previous one.
*
* The new thread gets its own copy of the current registers and stack.
*
* Params:
*   out_ = register to store the thread reference in
*   a = register holding how many instructions to jump (signed)
*/
void* forkRelative(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto threadPC = pc + *cast(long*)&registers[pc.a];
	registers[pc.out_] = newThread(threadPC, env, sp);
	mixin(mizuNext);
}

/**
* Forks a new thread whose program counter starts at an offset relative to
* this instruction.
*
* Params:
*   out_ = register to store the thread reference in
*   immediate = how many instructions to jump (signed)
*/
void* forkRelativeImmediate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto threadPC = pc + pc.immediateSigned;
	registers[pc.out_] = newThread(threadPC, env, sp);
	mixin(mizuNext);
}

/**
* Forks a new thread with its program counter set to a value, usually the
* output of a `findLabel`.
*
* Params:
*   out_ = register to store the thread reference in
*   a = register holding the address of the instruction to start at
*/
void* forkTo(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	auto threadPC = cast(Opcode*) registers[pc.a];
	registers[pc.out_] = newThread(threadPC, env, sp);
	mixin(mizuNext);
}

/**
* Waits for the provided thread to finish and releases its reference.
*
* Params:
*   a = register holding the thread to wait for
*   b = register holding a value to overwrite `a` with (defaults to zero)
*/
void* joinThread(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.thread : threadJoin = join;
		auto thread = cast(BcThread*) registers[pc.a];
		if (thread !is null) {
			threadJoin(*thread);
			fpFree(thread);
			registers[pc.a] = registers[pc.b];
		}
	} else {
		immutable contextId = cast(size_t) registers[pc.a];
		if (contextId) { // Can't join the main thread!
			// Not finished yet: rewind so this same instruction runs again.
			if (!Coroutine.getContext(contextId).done())
				--pc;
			else registers[pc.a] = registers[pc.b];
		}
	}
	mixin(mizuNext);
}

/**
* Sleeps for the given number of microseconds.
*
* Params:
*   out_ = scratch register the coroutine fallback uses to track the deadline
*   a = register holding the number of microseconds to sleep
*/
void* sleepMicroseconds(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	delay(registers[pc.a], pc, registers[pc.out_]);
	mixin(mizuNext);
}

/**
* Creates an inter-thread communication channel, which can buffer a number of
* values or just one.
*
* Channels send and receive register-sized binary blobs.
*
* Params:
*   out_ = register to store the channel reference in
*   a = register holding the capacity of the channel's buffer (zero means one item)
*/
void* channelCreate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	immutable capacity = registers[pc.a];
	static if (!noHardwareThreads) {
		import bc.channel : channelCreate_ = create;
		registers[pc.out_] = cast(size_t) channelCreate_!ulong(capacity < 1 ? 1 : capacity);
	} else {
		import fp.dynarray : reserve;
		ulong* channel = null;
		reserve(channel, capacity < 1 ? 1 : capacity);
		registers[pc.out_] = cast(size_t) channel;
	}
	mixin(mizuNext);
}

/**
* Closes the provided channel and releases its reference.
*
* Params:
*   a = register holding the channel to free
*   b = register holding a value to overwrite `a` with (defaults to zero)
*/
void* channelClose(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.channel : channelClose_ = close, channelFree = free;
		auto channel = cast(Channel*) registers[pc.a];
		if (channel is null) fatal("Channel does not exist.");
		channelClose_(channel);
		channelFree(channel);
	} else {
		import fp.dynarray : dynFree = free;
		auto channel = cast(ulong*) registers[pc.a];
		if (channel !is null) dynFree(channel);
	}
	registers[pc.a] = registers[pc.b];
	mixin(mizuNext);
}

/**
* Blocks until there is an item to receive from the channel.
*
* Params:
*   out_ = register to store the binary blob read from the channel in
*   a = register holding the channel to read from
*/
void* channelReceive(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.channel : channelReceive_ = receive;
		auto channel = cast(Channel*) registers[pc.a];
		if (channel is null) fatal("Channel does not exist.");
		auto received = channelReceive_(channel);
		registers[pc.out_] = received.isNull ? 0 : received.get;
	} else {
		import fp.dynarray : length, removeAt;
		auto channel = cast(ulong*) registers[pc.a];
		if (channel is null) fatal("Channel does not exist.");
		if (length(channel) == 0)
			--pc; // Nothing to receive yet: yield and try again.
		else {
			registers[pc.out_] = channel[0];
			removeAt(channel, 0);
			registers[pc.a] = cast(size_t) channel; // removeAt may reallocate.
		}
	}
	mixin(mizuNext);
}

/**
* Blocks until the channel has room for a new value.
*
* Params:
*   a = register holding the channel to send to
*   b = register holding the binary blob to send
*/
void* channelSend(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.channel : channelSend_ = send;
		auto channel = cast(Channel*) registers[pc.a];
		if (channel is null) fatal("Channel does not exist.");
		channelSend_(channel, registers[pc.b]);
	} else {
		import fp.dynarray : length, capacity, pushBack;
		auto channel = cast(ulong*) registers[pc.a];
		if (channel is null) fatal("Channel does not exist.");
		if (length(channel) == capacity(channel))
			--pc; // Full: yield and try again.
		else {
			pushBack(channel, registers[pc.b]);
			registers[pc.a] = cast(size_t) channel; // pushBack may reallocate.
		}
	}
	mixin(mizuNext);
}

/**
* Creates a read/write lockable mutex.
*
* Params:
*   out_ = register to store the mutex reference in
*
* Note:
*   With the coroutine fallback there is no OS mutex; the register itself
*   holds the lock state (0 unlocked, -1 write locked, n>0 read locked).
*
*   That makes the lock private to one context, because forking copies the
*   whole register file: two contexts hold a lock each rather than sharing
*   one. `mutexTryWriteLock` and `mutexTryReadLock` still report honestly
*   against the caller's own state, but `mutexWriteLock` and `mutexReadLock`
*   yield waiting for a release no other context can perform, so a contended
*   blocking lock hangs. Use a channel to synchronise coroutine contexts.
*/
void* mutexCreate(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.mutex : mutexCreate_ = create;
		// `create` heap-allocates and returns the mutex itself: a
		// `pthread_rwlock_t` binds to the address it was initialised at, so
		// boxing a returned-by-value one here would hand out a corrupt copy.
		auto mutex = mutexCreate_();
		if (mutex is null) fatal("Failed to allocate a mutex.");
		registers[pc.out_] = cast(size_t) mutex;
	} else
		registers[pc.out_] = 0;
	mixin(mizuNext);
}

/**
* Frees a mutex.
*
* Params:
*   a = register holding the mutex to free
*   b = register holding a value to overwrite `a` with (defaults to zero)
*/
void* mutexFree(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.mutex : mutexFree_ = free;
		auto mutex = cast(BcMutex*) registers[pc.a];
		if (mutex is null) fatal("Mutex does not exist.");
		mutexFree_(mutex);
	}
	registers[pc.a] = registers[pc.b];
	mixin(mizuNext);
}

/**
* Blocks until an exclusive (writing) lock can be taken on the mutex.
*
* Params:
*   a = register holding the mutex to lock
*/
void* mutexWriteLock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.mutex : writeLock;
		auto mutex = cast(BcMutex*) registers[pc.a];
		if (mutex is null) fatal("Mutex does not exist.");
		writeLock(mutex);
	} else {
		if (registers[pc.a] != 0)
			--pc; // Already locked: yield and try again.
		else registers[pc.a] = ulong.max; // Mark it exclusively locked.
	}
	mixin(mizuNext);
}

/**
* Attempts to take an exclusive (writing) lock on the mutex.
*
* Params:
*   out_ = register set to one if the lock was taken, zero otherwise
*   a = register holding the mutex to lock
*/
void* mutexTryWriteLock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.mutex : tryWriteLock;
		auto mutex = cast(BcMutex*) registers[pc.a];
		if (mutex is null) fatal("Mutex does not exist.");
		registers[pc.out_] = tryWriteLock(mutex);
	} else {
		if (registers[pc.a] == 0) {
			registers[pc.a] = ulong.max;
			registers[pc.out_] = 1;
		} else registers[pc.out_] = 0;
	}
	mixin(mizuNext);
}

/**
* Releases an exclusive (writing) lock so another thread can take it.
*
* Params:
*   a = register holding the mutex to unlock
*/
void* mutexWriteUnlock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.mutex : writeUnlock;
		auto mutex = cast(BcMutex*) registers[pc.a];
		if (mutex is null) fatal("Mutex does not exist.");
		writeUnlock(mutex);
	} else {
		if (registers[pc.a] == ulong.max)
			registers[pc.a] = 0;
	}
	mixin(mizuNext);
}

/**
* Blocks until a shared (reading) lock can be taken on the mutex.
*
* Any number of threads may hold a reading lock at once, but only one may
* hold the writing lock.
*
* Params:
*   a = register holding the mutex to lock
*/
void* mutexReadLock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.mutex : readLock;
		auto mutex = cast(BcMutex*) registers[pc.a];
		if (mutex is null) fatal("Mutex does not exist.");
		readLock(mutex);
	} else {
		if (*cast(long*)&registers[pc.a] < 0)
			--pc; // Exclusively locked: yield and try again.
		else ++registers[pc.a]; // Mark another active shared lock.
	}
	mixin(mizuNext);
}

/**
* Attempts to take a shared (reading) lock on the mutex.
*
* Params:
*   out_ = register set to one if the lock was taken, zero otherwise
*   a = register holding the mutex to lock
*/
void* mutexTryReadLock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.mutex : tryReadLock;
		auto mutex = cast(BcMutex*) registers[pc.a];
		if (mutex is null) fatal("Mutex does not exist.");
		registers[pc.out_] = tryReadLock(mutex);
	} else {
		if (*cast(long*)&registers[pc.a] >= 0) {
			++registers[pc.a];
			registers[pc.out_] = 1;
		} else registers[pc.out_] = 0;
	}
	mixin(mizuNext);
}

/**
* Releases a shared (reading) lock so another thread can take it.
*
* Params:
*   a = register holding the mutex to unlock
*/
void* mutexReadUnlock(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	static if (!noHardwareThreads) {
		import bc.mutex : readUnlock;
		auto mutex = cast(BcMutex*) registers[pc.a];
		if (mutex is null) fatal("Mutex does not exist.");
		readUnlock(mutex);
	} else {
		if (*cast(long*)&registers[pc.a] > 0)
			--registers[pc.a];
	}
	mixin(mizuNext);
}

unittest {
	// `monotonicMicroseconds` only backs the coroutine scheduler's `delay`, so
	// in a hardware-thread build nothing else reaches it.
	immutable first = monotonicMicroseconds();
	immutable second = monotonicMicroseconds();
	assert(second >= first);
}

// Only the hardware-thread `delay` really sleeps; the coroutine one returns
// false and rewinds until its deadline passes, never touching `nanosleep`.
static if (!noHardwareThreads)
version(Posix)
unittest {
	// A signal arriving mid-sleep makes `nanosleep` return early with the
	// time that was left, and `delay` has to go back to sleep for the
	// remainder rather than returning short. A repeating 2ms timer interrupts
	// a 30ms delay about fifteen times over.
	import core.sys.posix.signal : sigaction_t, sigaction, sigemptyset, SIGALRM;
	import core.sys.posix.sys.time : itimerval, setitimer;

	// druntime does not define `ITIMER_REAL` on macOS; `<sys/time.h>` has it
	// as 0, the same value every other platform uses.
	version(OSX) enum ITIMER_REAL = 0;
	else import core.sys.posix.sys.time : ITIMER_REAL;

	static extern(C) void onAlarm(int) @nogc nothrow {}

	// No SA_RESTART: `nanosleep` is never restarted anyway, but the handler
	// has to exist for the signal not to kill the process.
	sigaction_t action, previous;
	sigemptyset(&action.sa_mask);
	action.sa_handler = &onAlarm;
	sigaction(SIGALRM, &action, &previous);

	itimerval timer;
	timer.it_value.tv_usec = 2_000;
	timer.it_interval.tv_usec = 2_000;
	setitimer(ITIMER_REAL, &timer, null);

	immutable start = monotonicMicroseconds();
	Opcode instruction;
	auto pc = &instruction;
	ulong storage = 0;
	immutable finished = delay(30_000, pc, storage);
	immutable elapsed = monotonicMicroseconds() - start;

	// Stop the timer and put the old handler back before asserting anything.
	itimerval off;
	setitimer(ITIMER_REAL, &off, null);
	sigaction(SIGALRM, &previous, null);

	assert(finished);
	// Interrupted or not, the whole delay was served. The bound is loose
	// because a machine under load can only oversleep, never undersleep.
	assert(elapsed >= 25_000);
}
