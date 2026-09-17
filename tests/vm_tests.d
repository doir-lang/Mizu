/**
* End-to-end tests: real Mizu programs, run by the real VM, checked against
* the values they are supposed to produce.
*
* These are the D ports of `tests/fib.cpp` and `tests/bubble.cpp`, plus
* coverage of the pieces those two do not reach.
*/
module vm_tests;

import mizu;

@nogc nothrow:

/// Runs `program` to completion in a fresh environment and returns its registers.
private void run(const(Opcode)[] program, ref RegistersAndStack env) @trusted {
	setupEnvironment(env, program);
	startFromEnvironment(program, env);
}

/*
* `mizu.exception.fatal` ends the process, so the only way to watch a misuse
* being caught from inside that process is to intercept the `SIGABRT` that
* `abort` raises and jump back out of the handler. Both platforms do exactly
* that and differ only in how a handler is installed and how the jump buffer
* is spelled, so that is all each branch below defines; `aborts` is shared.
*/
version(Posix) {
	import core.sys.posix.signal : sigaction_t, sigaction, sigemptyset, SIGABRT;

	// druntime declares `sigjmp_buf` as a static array, which D passes by
	// value rather than decaying to a pointer the way C does, so bind these
	// by pointer instead. `__sigsetjmp` is what glibc and uClibc export; every
	// other platform exports it under its own name. See the matching note in
	// `mizu.exception`.
	version(CRuntime_Glibc) version = MizuUnderscoredSigsetjmp;
	else version(CRuntime_UClibc) version = MizuUnderscoredSigsetjmp;

	version(MizuUnderscoredSigsetjmp) {
		private extern(C) @nogc nothrow int __sigsetjmp(void* buffer, int saveMask);
		private alias sigsetjmpByPointer = __sigsetjmp;
	} else {
		private extern(C) @nogc nothrow int sigsetjmp(void* buffer, int saveMask);
		private alias sigsetjmpByPointer = sigsetjmp;
	}

	private extern(C) @nogc nothrow void siglongjmp(void* buffer, int value);

	// druntime does not declare `sigjmp_buf` at all on Darwin, and where it
	// does the layout is the C library's business rather than ours, so
	// reserve a buffer large enough for every one of them instead: glibc's is
	// the biggest at a little under 600 bytes on PowerPC, and macOS' is under
	// 200. This is what the Windows branch below already does.
	private __gshared align(16) ubyte[1024] abortEscape;

	/// What `installAbortHandler` has to give back to `restoreAbortHandler`.
	private alias SavedAbortHandler = sigaction_t;

	private void installAbortHandler(out SavedAbortHandler saved) {
		sigaction_t action;
		sigemptyset(&action.sa_mask);
		action.sa_handler = &onAbort;
		sigaction(SIGABRT, &action, &saved);
	}

	private void restoreAbortHandler(ref SavedAbortHandler saved) {
		sigaction(SIGABRT, &saved, null);
	}
} else version(Windows) {
	// The MS C runtime calls a `SIGABRT` handler as an ordinary function from
	// inside `abort`, rather than through the operating system's signal
	// machinery, so leaving it is an ordinary `longjmp` rather than a
	// `siglongjmp`. `jmp_buf`'s layout is not ours to know -- it is 256 bytes
	// on x86-64 and smaller elsewhere -- hence the generous reserve, and
	// handing `_setjmp` a null frame is the documented way to ask for a plain
	// register restore instead of an SEH unwind.
	private __gshared align(16) ubyte[512] abortEscape;

	private extern(C) @nogc nothrow {
		int _setjmp(void* buffer, void* frame);
		void longjmp(void* buffer, int value);
	}

	// `core.stdc.signal` declares `signal` without `@nogc nothrow`, which this
	// module is, so bind it here instead. `SIGABRT` is 22 on Windows.
	private alias AbortHandler = extern(C) void function(int) @nogc nothrow;
	private extern(C) @nogc nothrow AbortHandler signal(int sig, AbortHandler handler);
	private enum int SIGABRT = 22;

	/// Ditto
	private alias SavedAbortHandler = AbortHandler;

	private void installAbortHandler(out SavedAbortHandler saved) {
		saved = signal(SIGABRT, &onAbort);
	}

	private void restoreAbortHandler(ref SavedAbortHandler saved) {
		signal(SIGABRT, saved);
	}
}

private extern(C) void onAbort(int) @nogc nothrow {
	// Windows resets a handler to the default as it raises, so a test whose
	// second `fatal` mattered would find nothing installed. Putting it back
	// here rather than in `aborts` keeps one arming good for any number of
	// aborts. POSIX `sigaction` does not reset, so this is a no-op there.
	version(Windows) signal(SIGABRT, &onAbort);
	version(Posix) siglongjmp(abortEscape.ptr, 1);
	else version(Windows) longjmp(abortEscape.ptr, 1);
}

/**
* Runs `attempt` and reports whether it reached `mizu.exception.fatal`.
*
* `fatal` aborts the process, so the only way to watch a misuse being caught
* is to catch the `SIGABRT` and jump back out of the handler; the unit test in
* `mizu.exception` explains why that leaves the process unharmed. The
* abandoned VM frames do not leak, because Mizu's dispatch tail-calls and so
* only ever occupies the one frame.
*/
private bool aborts(scope void delegate() @nogc nothrow attempt) @trusted {
	SavedAbortHandler saved;
	installAbortHandler(saved);

	// `setjmp` records the frame it was called from, so it has to be called
	// from the frame being returned to: spelled out here rather than hidden
	// behind a helper that would have returned before the jump arrived.
	version(Posix) immutable landed = sigsetjmpByPointer(abortEscape.ptr, 1) != 0;
	else version(Windows) immutable landed = _setjmp(abortEscape.ptr, null) != 0;

	// `__gshared` because a local's value across a `longjmp` is whatever the
	// optimiser left in its register.
	__gshared bool aborted;
	aborted = true;
	if (!landed) {
		attempt();
		aborted = false;
	}

	restoreAbortHandler(saved);

	// Jumping out of the handler abandons the VM part way through a
	// program, so `startFromEnvironment` never reached its own cleanup.
	// The coroutine scheduler's context list is global, and a leftover
	// context points at the abandoned run's stack frame, which the next
	// program would then be scheduled into.
	static if (noHardwareThreads) Coroutine.clear();

	return aborted;
}

/*
* The host functions the FFI tests call back into.
*
* They are `export`ed because a Mizu program reaches the host through library
* handle zero, which is "look in the executable itself": on Windows that is
* `GetProcAddress` against the executable's export table, so a symbol has to
* be named there to be found at all. On POSIX `--export-dynamic` (see the
* `unittest` configuration in `dub.json`) publishes them the same way.
*
* Using Mizu's own symbols rather than the C library's is what makes these
* tests platform independent: `strlen` and friends live in the process on
* every platform, but only POSIX lets the executable hand them out again.
*/
export extern(C) {
	/// A pointer in and a `u64` out.
	ulong mizuTestLength(const(char)* text) @nogc nothrow {
		import core.stdc.string : strlen;
		return strlen(text);
	}

	/// An `i32` in and an `i32` out, for the signed 32 bit call path.
	int mizuTestNegate(int value) @nogc nothrow { return -value; }

	/// A pointer in and nothing out, for the call path that has no result.
	/// It counts its calls, so a test can tell that it really ran.
	void mizuTestDiscard(void*) @nogc nothrow { ++mizuTestDiscardCalls; }
}

/// How many times `mizuTestDiscard` has been called.
private __gshared uint mizuTestDiscardCalls = 0;

unittest {
	// Arithmetic and immediates: t0 = 40, t1 = 2, t2 = t0 + t1, t3 = t0 / t1.
	static immutable Opcode[6] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(40),
		Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
		Opcode(&add, Registers.t(2), Registers.t(0), Registers.t(1)),
		Opcode(&divide, Registers.t(3), Registers.t(0), Registers.t(1)),
		Opcode(&modulus, Registers.t(4), Registers.t(0), Registers.t(1)),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(0)] == 40);
	assert(env.memory[Registers.t(2)] == 42);
	assert(env.memory[Registers.t(3)] == 20);
	assert(env.memory[Registers.t(4)] == 0);
	assert(env.memory[0] == 0); // x0 stays zero.
}

unittest {
	// A 32 bit immediate really does survive both halves, and the upper
	// immediate lands in the top 32 bits.
	static immutable Opcode[3] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(0xDEADBEEF),
		Opcode(&loadUpperImmediate, Registers.t(0)).setImmediate(0xCAFEBABE),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);
	assert(env.memory[Registers.t(0)] == 0xCAFEBABE_DEADBEEF);
}

unittest {
	// The stack: push, store, load back, pop.
	static immutable Opcode[7] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(0x1234),
		Opcode(&stackPushImmediate).setImmediate(8),
		Opcode(&loadImmediate, Registers.t(1)).setImmediate(0),
		Opcode(&stackStoreU64, 0, Registers.t(0), Registers.t(1)),
		Opcode(&stackLoadU64, Registers.t(2), Registers.t(1)),
		Opcode(&stackPopImmediate).setImmediate(8),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);
	assert(env.memory[Registers.t(2)] == 0x1234);
}

unittest {
	// A counted loop, exercising comparison + backward branch:
	// t0 = 0; do { t0 += 1 } while (t0 < 10)
	static immutable Opcode[6] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(0),
		Opcode(&loadImmediate, Registers.t(1)).setImmediate(1),
		Opcode(&loadImmediate, Registers.t(2)).setImmediate(10),
		Opcode(&add, Registers.t(0), Registers.t(0), Registers.t(1)),
		Opcode(&setIfLess, Registers.t(3), Registers.t(0), Registers.t(2)),
		Opcode(&branchRelativeImmediate, 0, Registers.t(3)).setBranchImmediate(-2),
	];
	// The branch falls through to one-past-the-end, so give the program a halt.
	static immutable Opcode[7] full = program ~ [Opcode(&halt)];

	RegistersAndStack env;
	run(full[], env);
	assert(env.memory[Registers.t(0)] == 10);
}

unittest {
	// Float math in the float registers, then read back as an integer.
	static immutable Opcode[8] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(7),
		Opcode(&convertToF64, Registers.t(0), Registers.t(0)),
		Opcode(&loadImmediate, Registers.t(1)).setImmediate(2),
		Opcode(&convertToF64, Registers.t(1), Registers.t(1)),
		Opcode(&divideF64, Registers.t(2), Registers.t(0), Registers.t(1)),
		Opcode(&multiplyF64, Registers.t(3), Registers.t(2), Registers.t(1)),
		Opcode(&convertFromF64, Registers.t(4), Registers.t(3)),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(*cast(double*)&env.memory[Registers.t(2)] == 3.5);
	assert(env.memory[Registers.t(4)] == 7);
}

unittest {
	// f32 predicates: 0.0/0.0 is nan, 1.0/0.0 is infinity, -1.0 is negative.
	static immutable Opcode[11] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediateF32(0.0f),
		Opcode(&loadImmediate, Registers.t(1)).setImmediateF32(1.0f),
		Opcode(&loadImmediate, Registers.t(2)).setImmediateF32(-1.0f),
		Opcode(&divideF32, Registers.t(3), Registers.t(0), Registers.t(0)),
		Opcode(&divideF32, Registers.t(4), Registers.t(1), Registers.t(0)),
		Opcode(&setIfNanF32, Registers.t(5), Registers.t(3)),
		Opcode(&setIfInfinityF32, Registers.t(6), Registers.t(4)),
		Opcode(&setIfNegativeF32, Registers.t(7), Registers.t(2)),
		Opcode(&setIfPositiveF32, Registers.t(8), Registers.t(1)),
		Opcode(&sqrtF32, Registers.t(9), Registers.t(1)),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(5)] == 1); // nan
	assert(env.memory[Registers.t(6)] == 1); // infinity
	assert(env.memory[Registers.t(7)] == 1); // negative
	assert(env.memory[Registers.t(8)] == 1); // positive
	assert(*cast(float*)&env.memory[Registers.t(9)] == 1.0f);
}

unittest {
	// label / findLabel / jumpTo: a function call and return.
	static immutable Opcode[9] program = [
		Opcode(&findLabel, 200).setImmediate(label2immediate("dbl")),
		Opcode(&loadImmediate, Registers.a(0)).setImmediate(21),
		Opcode(&jumpTo, Registers.ra, 200),
		Opcode(&halt),

		// dbl: a0 = a0 + a0; return
		Opcode(&label).setImmediate(label2immediate("dbl")),
		Opcode(&add, Registers.a(0), Registers.a(0), Registers.a(0)),
		Opcode(&jumpTo, 0, Registers.ra),
		Opcode(&halt),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);
	assert(env.memory[Registers.a(0)] == 42);
}

/// The D port of `tests/fib.cpp`: recursive fib(n) through Mizu's own stack.
private immutable Opcode[30] fibProgram = [
	Opcode(&findLabel, 200).setImmediate(label2immediate("fib")),
	// a0 = fib(a0)
	Opcode(&jumpTo, Registers.ra, 200),
	Opcode(&halt),

	// Recursive Fibonacci
	Opcode(&label).setImmediate(label2immediate("fib")),
	// if (a0 >= 3) skip "return 1"
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(3),
	Opcode(&setIfGreaterEqual, Registers.t(0), Registers.a(0), Registers.t(0)),
	Opcode(&branchRelativeImmediate, 0, Registers.t(0)).setBranchImmediate(3),
	// return 1
	Opcode(&loadImmediate, Registers.a(0)).setImmediate(1),
	Opcode(&jumpTo, 0, Registers.ra),
	// save ra, a2, a3
	Opcode(&stackPushImmediate, 0).setImmediate(24),
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(24),
	Opcode(&stackStoreU64, 0, Registers.ra, Registers.t(0)),
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(16),
	Opcode(&stackStoreU64, 0, Registers.a(2), Registers.t(0)),
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
	Opcode(&stackStoreU64, 0, Registers.a(3), Registers.t(0)),
	// a2 = a0 - 1
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
	Opcode(&subtract, Registers.a(2), Registers.a(0), Registers.t(0)),
	// a3 = a0 - 2
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(2),
	Opcode(&subtract, Registers.a(3), Registers.a(0), Registers.t(0)),
	// a2 = fib(a2)
	Opcode(&add, Registers.a(0), Registers.a(2), 0),
	Opcode(&jumpTo, Registers.ra, 200),
	Opcode(&add, Registers.a(2), Registers.a(0), 0),
	// a0 = fib(a3)
	Opcode(&add, Registers.a(0), Registers.a(3), 0),
	Opcode(&jumpTo, Registers.ra, 200),
	// a0 = a2 + a0
	Opcode(&add, Registers.a(0), Registers.a(2), Registers.a(0)),
	// restore ra, a2, a3
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(24),
	Opcode(&stackLoadU64, Registers.ra, Registers.t(0)),
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(16),
	Opcode(&stackLoadU64, Registers.a(2), Registers.t(0)),
];

/// Ditto (split only because a 34-entry literal is easier to read in two halves)
private immutable Opcode[4] fibProgramTail = [
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
	Opcode(&stackLoadU64, Registers.a(3), Registers.t(0)),
	Opcode(&stackPopImmediate).setImmediate(24),
	Opcode(&jumpTo, 0, Registers.ra), // return
];

unittest {
	static immutable Opcode[34] program = fibProgram ~ fibProgramTail;

	// fib(1) = fib(2) = 1, then the usual sequence.
	static immutable ulong[11] expected = [0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55];

	foreach (n; 1 .. expected.length) {
		RegistersAndStack env;
		setupEnvironment(env, program[]);
		env.memory[Registers.a(0)] = n;
		startFromEnvironment(program[], env);
		assert(env.memory[Registers.a(0)] == expected[n]);
	}
}

unittest {
	// A deep recursion, to prove the tail-call dispatch really does reuse one
	// stack frame: fib(27) is ~600k instruction dispatches.
	static immutable Opcode[34] program = fibProgram ~ fibProgramTail;

	RegistersAndStack env;
	setupEnvironment(env, program[]);
	env.memory[Registers.a(0)] = 27;
	startFromEnvironment(program[], env);
	assert(env.memory[Registers.a(0)] == 196_418);
}

private immutable ulong[10] unsorted = [179, 1630, 754, 259, 858, 970, 310, 1612, 1269, 1000];

unittest {
	// The D port of `tests/bubble.cpp`, shortened: bubble sort an array that
	// has been copied onto Mizu's stack via the unsafe pointer instructions,
	// then check it really is sorted.
	//
	// Note: the C++ original's inner loop guard is `i >= size`, but the pair it
	// compares is (i, i + 1), so it reads and writes one element past the array
	// it was given. The guard here is `i >= size - 1`, held in register 205.

	// Host pointer immediates are not compile-time constants, so unlike the
	// other programs here this one is built at run time.
	Opcode[36] program = [
		Opcode(&findLabel, 200).setImmediate(label2immediate("bub")),   // outer loop
		Opcode(&findLabel, 201).setImmediate(label2immediate("innr")),  // inner loop
		Opcode(&findLabel, 202).setImmediate(label2immediate("done")),  // finished
		Opcode(&loadImmediate, 204).setImmediate(ulong.sizeof),         // element size
		Opcode(&loadImmediate, 206).setImmediate(1),                    // the constant 1
		// a0 (size) = unsorted.length, 205 = size - 1
		Opcode(&loadImmediate, Registers.a(0)).setImmediate(unsorted.length),
		Opcode(&subtract, 205, Registers.a(0), 206),
		// Reserve size * 8 bytes of stack and copy the array into it.
		Opcode(&multiply, Registers.t(0), 204, Registers.a(0)),
		Opcode(&stackPush, 0, Registers.t(0)),
		Opcode(&pointerToStack, Registers.t(1)),
		Opcode(&loadImmediate, Registers.t(2)).setHostPointerLowerImmediate(unsorted.ptr),
		Opcode(&loadUpperImmediate, Registers.t(2)).setHostPointerUpperImmediate(unsorted.ptr),
		Opcode(&copyMemory, Registers.t(1), Registers.t(2), Registers.t(0)),
		// a1 (changed) = true
		Opcode(&loadImmediate, Registers.a(1)).setImmediate(1),
		Opcode(&label).setImmediate(label2immediate("bub")),
			// if (!changed) goto done
			Opcode(&setIfEqual, Registers.t(0), Registers.a(1), 0),
			Opcode(&branchTo, 0, Registers.t(0), 202),
			Opcode(&loadImmediate, Registers.a(1)).setImmediate(0), // changed = false
			Opcode(&loadImmediate, Registers.a(2)).setImmediate(0), // i = 0
			Opcode(&label).setImmediate(label2immediate("innr")),
				// if (i >= size - 1) goto bub
				Opcode(&setIfGreaterEqual, Registers.t(0), Registers.a(2), 205),
				Opcode(&branchTo, 0, Registers.t(0), 200),
				// t0 = i, then i += 1, so t0 is "i - 1" from here on
				Opcode(&add, Registers.t(0), Registers.a(2), 0),
				Opcode(&add, Registers.a(2), Registers.a(2), 206),
				// t0 = stack[i - 1] at offset t2, t1 = stack[i] at offset t3
				Opcode(&multiply, Registers.t(2), Registers.t(0), 204),
				Opcode(&stackLoadU64, Registers.t(0), Registers.t(2)),
				Opcode(&multiply, Registers.t(3), Registers.a(2), 204),
				Opcode(&stackLoadU64, Registers.t(1), Registers.t(3)),
				// if (stack[i] >= stack[i - 1]) continue
				Opcode(&setIfGreaterEqual, Registers.t(4), Registers.t(1), Registers.t(0)),
				Opcode(&branchTo, 0, Registers.t(4), 201),
				// swap them and note that something changed
				Opcode(&stackStoreU64, 0, Registers.t(1), Registers.t(2)),
				Opcode(&stackStoreU64, 0, Registers.t(0), Registers.t(3)),
				Opcode(&loadImmediate, Registers.a(1)).setImmediate(1),
				Opcode(&jumpTo, 0, 201),
		Opcode(&label).setImmediate(label2immediate("done")),
		Opcode(&halt),
	];

	RegistersAndStack env;
	setupEnvironment(env, program[]);
	startFromEnvironment(program[], env);

	// The sorted array is still on the stack, size * 8 bytes above the bottom.
	auto sorted = cast(const(ulong)*)(env.stackBottom - unsorted.length * ulong.sizeof);
	foreach (i; 1 .. unsorted.length)
		assert(sorted[i - 1] <= sorted[i]);
	// And it is a permutation of the input, not merely something sorted.
	ulong inputSum = 0, outputSum = 0;
	foreach (i; 0 .. unsorted.length) { inputSum += unsorted[i]; outputSum += sorted[i]; }
	assert(inputSum == outputSum);
}

unittest {
	// unsafe.allocate / copyMemory / freeAllocated round trip through the heap.
	static immutable Opcode[9] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
		Opcode(&allocate, Registers.t(1), Registers.t(0)),
		Opcode(&loadImmediate, Registers.t(2)).setImmediate(0xABCD),
		Opcode(&pointerToRegister, Registers.t(3), Registers.t(2)),
		Opcode(&copyMemory, Registers.t(1), Registers.t(3), Registers.t(0)),
		// Read it back through a second copy, into t4.
		Opcode(&pointerToRegister, Registers.t(5), Registers.t(4)),
		Opcode(&copyMemory, Registers.t(5), Registers.t(1), Registers.t(0)),
		Opcode(&freeAllocated, 0, Registers.t(1), 0),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);
	assert(env.memory[Registers.t(4)] == 0xABCD);
	assert(env.memory[Registers.t(1)] == 0); // freeAllocated cleared it.
}

unittest {
	// Fork a thread, hand a value back through a channel, and join it.
	static immutable Opcode[12] program = [
		Opcode(&findLabel, 200).setImmediate(label2immediate("work")),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(1), // channel capacity
		Opcode(&channelCreate, 220, Registers.t(0)),
		Opcode(&forkTo, 221, 200),
		Opcode(&channelReceive, 222, 220),
		Opcode(&joinThread, 0, 221, 0),
		Opcode(&channelClose, 0, 220, 0),
		Opcode(&halt),

		// work: send 42 down the channel and stop.
		Opcode(&label).setImmediate(label2immediate("work")),
		Opcode(&loadImmediate, Registers.t(1)).setImmediate(42),
		Opcode(&channelSend, 0, 220, Registers.t(1)),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[222] == 42); // What the thread sent.
	assert(env.memory[221] == 0);  // joinThread cleared the handle.
	assert(env.memory[220] == 0);  // channelClose cleared the channel.
}

unittest {
	// Mutexes: a write lock excludes, and after unlocking a read lock is free.
	static immutable Opcode[7] program = [
		Opcode(&mutexCreate, Registers.t(0)),
		Opcode(&mutexTryWriteLock, Registers.t(1), Registers.t(0)),
		Opcode(&mutexWriteUnlock, 0, Registers.t(0)),
		Opcode(&mutexTryReadLock, Registers.t(2), Registers.t(0)),
		Opcode(&mutexReadUnlock, 0, Registers.t(0)),
		Opcode(&mutexFree, 0, Registers.t(0), 0),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(1)] == 1); // Took the write lock.
	assert(env.memory[Registers.t(2)] == 1); // And the read lock after unlocking.
	assert(env.memory[Registers.t(0)] == 0); // mutexFree cleared the handle.
}

unittest {
	// sleepMicroseconds returns, and really does wait.
	static immutable Opcode[3] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(2000),
		Opcode(&sleepMicroseconds, Registers.t(1), Registers.t(0)),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);
}

unittest {
	// A real foreign call: `mizuTestLength("Hello 世界")` through libffi.
	//
	// Register zero is the library handle, which the loader reads as "look in
	// the host executable", so the function is found without naming a library.
	import mizu.ffi;

	static immutable char[13] subject = "Hello 世界\0"; // 12 bytes plus terminator
	static immutable char[16] symbol = "mizuTestLength\0\0";

	Opcode[13] program = [
		// Describe u64 mizuTestLength(void*).
		Opcode(&pushTypeU64),
		Opcode(&pushTypePointer),
		Opcode(&createInterface, 201),
		// 202 = &mizuTestLength
		Opcode(&loadImmediate, 203).setHostPointerLowerImmediate(symbol.ptr),
		Opcode(&loadUpperImmediate, 203).setHostPointerUpperImmediate(symbol.ptr),
		Opcode(&loadLibraryFunction, 202, 0, 203),
		// a0 = &subject
		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(subject.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(subject.ptr),
		// t0 = mizuTestLength(a0)
		Opcode(&callWithReturn, Registers.t(0), 202, 201),
		Opcode(&freeInterface, 0, 201, 0),
		Opcode(&halt),
		Opcode(&halt),
		Opcode(&halt),
	];

	RegistersAndStack env;
	setupEnvironment(env, program[]);
	startFromEnvironment(program[], env);

	assert(env.memory[202] != 0);                  // Found the function.
	assert(env.memory[Registers.t(0)] == 12);      // And it counted the bytes.
	assert(env.memory[201] == 0);                  // freeInterface cleared it.
}

unittest {
	// The FFI's void-returning call path. `mizuTestDiscard` ignores its
	// argument and has no result, so the only evidence it ran is the counter
	// it keeps -- which is the point: the call path being exercised is the one
	// that hands libffi a null return slot.
	import mizu.ffi;

	static immutable char[18] symbol = "mizuTestDiscard\0\0\0";

	immutable before = mizuTestDiscardCalls;

	Opcode[9] program = [
		Opcode(&pushTypeVoid),
		Opcode(&pushTypePointer),
		Opcode(&createInterface, 201),
		Opcode(&loadImmediate, 203).setHostPointerLowerImmediate(symbol.ptr),
		Opcode(&loadUpperImmediate, 203).setHostPointerUpperImmediate(symbol.ptr),
		Opcode(&loadLibraryFunction, 202, 0, 203),
		// a0 is still zero, and the callee ignores it anyway.
		Opcode(&call, 0, 202, 201),
		Opcode(&freeInterface, 0, 201, 0),
		Opcode(&halt),
	];

	RegistersAndStack env;
	setupEnvironment(env, program[]);
	startFromEnvironment(program[], env);

	assert(env.memory[202] != 0);                       // Found the function.
	assert(mizuTestDiscardCalls == before + 1);         // And it really ran.
	assert(env.memory[201] == 0);                       // freeInterface cleared it.
}

unittest {
	// The bitwise, shift and signed-comparison instructions.
	//
	// `loadImmediate` zero extends, so the negative values are built as a
	// low half plus an all-ones upper half.
	static immutable Opcode[16] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(0b1100),
		Opcode(&loadImmediate, Registers.t(1)).setImmediate(0b1010),
		Opcode(&loadImmediate, Registers.t(2)).setImmediate(2),
		// t3 = -16
		Opcode(&loadImmediate, Registers.t(3)).setImmediate(0xFFFFFFF0),
		Opcode(&loadUpperImmediate, Registers.t(3)).setImmediate(0xFFFFFFFF),

		Opcode(&bitwiseAnd, Registers.t(4), Registers.t(0), Registers.t(1)),
		Opcode(&bitwiseOr, Registers.t(5), Registers.t(0), Registers.t(1)),
		Opcode(&bitwiseXor, Registers.t(6), Registers.t(0), Registers.t(1)),
		Opcode(&shiftLeft, Registers.t(7), Registers.t(0), Registers.t(2)),
		Opcode(&shiftRightLogical, Registers.t(8), Registers.t(0), Registers.t(2)),
		// Arithmetic shift keeps the sign; logical shift would not.
		Opcode(&shiftRightArithmetic, Registers.t(9), Registers.t(3), Registers.t(2)),
		Opcode(&shiftRightLogical, Registers.t(10), Registers.t(3), Registers.t(2)),

		Opcode(&setIfNotEqual, Registers.t(11), Registers.t(0), Registers.t(1)),
		// Unsigned, -16 is huge; signed, it is less than 12.
		Opcode(&setIfLessSigned, Registers.t(12), Registers.t(3), Registers.t(0)),
		Opcode(&setIfGreaterEqualSigned, Registers.t(13), Registers.t(0), Registers.t(3)),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(4)] == 0b1000);
	assert(env.memory[Registers.t(5)] == 0b1110);
	assert(env.memory[Registers.t(6)] == 0b0110);
	assert(env.memory[Registers.t(7)] == 0b110000);
	assert(env.memory[Registers.t(8)] == 0b11);
	assert(*cast(long*)&env.memory[Registers.t(9)] == -4);
	assert(env.memory[Registers.t(10)] == 0x3FFFFFFF_FFFFFFFC);
	assert(env.memory[Registers.t(11)] == 1);
	assert(env.memory[Registers.t(12)] == 1);
	assert(env.memory[Registers.t(13)] == 1);
	// The unsigned comparison of the same pair goes the other way.
	assert(env.memory[Registers.t(3)] > env.memory[Registers.t(0)]);
}

unittest {
	// The width conversions. Only `convertToU64` replaces the whole register;
	// the narrower ones overwrite just the bottom of their destination, so
	// each destination starts out as all ones to show how much survives.
	static immutable Opcode[15] program = [
		// t0 = 0xCAFEBABE_DEADBEEF
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(0xDEADBEEF),
		Opcode(&loadUpperImmediate, Registers.t(0)).setImmediate(0xCAFEBABE),
		// t1..t4 = all ones
		Opcode(&loadImmediate, Registers.t(1)).setImmediate(0xFFFFFFFF),
		Opcode(&loadUpperImmediate, Registers.t(1)).setImmediate(0xFFFFFFFF),
		Opcode(&loadImmediate, Registers.t(2)).setImmediate(0xFFFFFFFF),
		Opcode(&loadUpperImmediate, Registers.t(2)).setImmediate(0xFFFFFFFF),
		Opcode(&loadImmediate, Registers.t(3)).setImmediate(0xFFFFFFFF),
		Opcode(&loadUpperImmediate, Registers.t(3)).setImmediate(0xFFFFFFFF),
		Opcode(&loadImmediate, Registers.t(4)).setImmediate(0xFFFFFFFF),
		Opcode(&loadUpperImmediate, Registers.t(4)).setImmediate(0xFFFFFFFF),

		Opcode(&convertToU64, Registers.t(1), Registers.t(0)),
		Opcode(&convertToU32, Registers.t(2), Registers.t(0)),
		Opcode(&convertToU16, Registers.t(3), Registers.t(0)),
		Opcode(&convertToU8, Registers.t(4), Registers.t(0)),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(1)] == 0xCAFEBABE_DEADBEEF);
	assert(env.memory[Registers.t(2)] == 0xFFFFFFFF_DEADBEEF);
	assert(env.memory[Registers.t(3)] == 0xFFFFFFFF_FFFFBEEF);
	assert(env.memory[Registers.t(4)] == 0xFFFFFFFF_FFFFFFEF);
}

unittest {
	// The 32, 16 and 8 bit stack moves, which the other programs here only
	// exercise at 64 bits. Each store writes the bottom of `t0` and each load
	// reads it straight back.
	static immutable Opcode[12] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(0x12345678),
		Opcode(&stackPushImmediate).setImmediate(8),
		Opcode(&loadImmediate, Registers.t(9)).setImmediate(0), // the offset

		Opcode(&stackStoreU32, Registers.t(1), Registers.t(0), Registers.t(9)),
		Opcode(&stackLoadU32, Registers.t(2), Registers.t(9)),
		Opcode(&stackStoreU16, Registers.t(3), Registers.t(0), Registers.t(9)),
		Opcode(&stackLoadU16, Registers.t(4), Registers.t(9)),
		Opcode(&stackStoreU8, Registers.t(5), Registers.t(0), Registers.t(9)),
		Opcode(&stackLoadU8, Registers.t(6), Registers.t(9)),

		Opcode(&stackPopImmediate).setImmediate(8),
		Opcode(&halt),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(1)] == 0x12345678);
	assert(env.memory[Registers.t(2)] == 0x12345678);
	assert(env.memory[Registers.t(3)] == 0x5678);
	assert(env.memory[Registers.t(4)] == 0x5678);
	assert(env.memory[Registers.t(5)] == 0x78);
	assert(env.memory[Registers.t(6)] == 0x78);
}

unittest {
	// The three unconditional/conditional relative jumps. `t0` stays zero
	// because every instruction that would change it is jumped over.
	static immutable Opcode[19] program = [
		/*  0 */ Opcode(&loadImmediate, Registers.t(0)).setImmediate(0),
		/*  1 */ Opcode(&loadImmediate, Registers.t(1)).setImmediate(3),
		/*  2 */ Opcode(&jumpRelative, Registers.t(2), Registers.t(1)), // -> 5
		/*  3 */ Opcode(&loadImmediate, Registers.t(0)).setImmediate(111),
		/*  4 */ Opcode(&halt),
		/*  5 */ Opcode(&loadImmediate, Registers.t(3)).setImmediate(1),
		/*  6 */ Opcode(&jumpRelativeImmediate, Registers.t(4)).setImmediateSigned(3), // -> 9
		/*  7 */ Opcode(&loadImmediate, Registers.t(0)).setImmediate(222),
		/*  8 */ Opcode(&halt),
		/*  9 */ Opcode(&loadImmediate, Registers.t(5)).setImmediate(1), // condition: true
		/* 10 */ Opcode(&loadImmediate, Registers.t(6)).setImmediate(3), // distance
		/* 11 */ Opcode(&branchRelative, Registers.t(7), Registers.t(5), Registers.t(6)), // -> 14
		/* 12 */ Opcode(&loadImmediate, Registers.t(0)).setImmediate(333),
		/* 13 */ Opcode(&halt),
		/* 14 */ Opcode(&loadImmediate, Registers.t(8)).setImmediate(1),
		// A false condition falls through instead of branching.
		/* 15 */ Opcode(&loadImmediate, Registers.t(9)).setImmediate(0),
		/* 16 */ Opcode(&branchRelative, Registers.t(10), Registers.t(9), Registers.t(6)),
		/* 17 */ Opcode(&loadImmediate, Registers.t(11)).setImmediate(1),
		/* 18 */ Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(0)] == 0);  // Every skipped store really was skipped.
	assert(env.memory[Registers.t(3)] == 1);
	assert(env.memory[Registers.t(8)] == 1);
	assert(env.memory[Registers.t(11)] == 1); // The untaken branch fell through.
	// Each jump leaves the address it would otherwise have continued at.
	assert(env.memory[Registers.t(2)] == cast(ulong)&program[3]);
	assert(env.memory[Registers.t(4)] == cast(ulong)&program[7]);
	assert(env.memory[Registers.t(7)] == cast(ulong)&program[12]);
	assert(env.memory[Registers.t(10)] == cast(ulong)&program[17]);
}

unittest {
	// The register (rather than immediate) forms of push and pop, plus
	// `offsetOfStackBottom`: the value it produces is the offset that makes
	// `stackLoadU64` read the place `pointerToStackBottom` would point at.
	static immutable Opcode[10] program = [
		/* 0 */ Opcode(&loadImmediate, Registers.t(0)).setImmediate(24),
		/* 1 */ Opcode(&stackPush, 0, Registers.t(0)),      // sp = bottom - 24
		/* 2 */ Opcode(&loadImmediate, Registers.t(1)).setImmediate(0xAAAA),
		/* 3 */ Opcode(&loadImmediate, Registers.t(2)).setImmediate(8),
		/* 4 */ Opcode(&stackStoreU64, 0, Registers.t(1), Registers.t(2)), // at bottom - 16
		/* 5 */ Opcode(&loadImmediate, Registers.t(3)).setImmediate(16),
		/* 6 */ Opcode(&offsetOfStackBottom, Registers.t(4), Registers.t(3)),
		/* 7 */ Opcode(&stackLoadU64, Registers.t(5), Registers.t(4)),
		/* 8 */ Opcode(&stackPop, 0, Registers.t(0)),
		/* 9 */ Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(4)] == 8);
	assert(env.memory[Registers.t(5)] == 0xAAAA);
}

unittest {
	// `findLabel` searches forward first and only then backward, so a label
	// that is behind the search is found by the second pass.
	static immutable Opcode[4] program = [
		/* 0 */ Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
		/* 1 */ Opcode(&label).setImmediate(label2immediate("bak")),
		/* 2 */ Opcode(&findLabel, Registers.t(1)).setImmediate(label2immediate("bak")),
		/* 3 */ Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);
	assert(env.memory[Registers.t(1)] == cast(ulong)&program[1]);

	// And a label that is nowhere leaves the register at zero.
	static immutable Opcode[2] missing = [
		Opcode(&findLabel, Registers.t(1)).setImmediate(label2immediate("nope")),
		Opcode(&halt),
	];

	RegistersAndStack none;
	run(missing[], none);
	assert(none.memory[Registers.t(1)] == 0);
}

unittest {
	// The debug instructions print to stdout and report how many characters
	// they wrote, so a non-zero result means the register really was printed.
	static immutable Opcode[4] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(42),
		Opcode(&debugPrint, Registers.t(1), Registers.t(0)),
		Opcode(&debugPrintBinary, Registers.t(2), Registers.t(0)),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(1)] > 0);
	assert(env.memory[Registers.t(2)] > 0);
}

unittest {
	// The `f32` arithmetic, conversions and comparisons.
	static immutable Opcode[22] program = [
		Opcode(&loadImmediate, Registers.t(0)).setImmediateF32(7.5f),
		Opcode(&loadImmediate, Registers.t(1)).setImmediateF32(2.5f),

		Opcode(&addF32, Registers.t(2), Registers.t(0), Registers.t(1)),      // 10.0
		Opcode(&subtractF32, Registers.t(3), Registers.t(0), Registers.t(1)), // 5.0
		Opcode(&multiplyF32, Registers.t(4), Registers.t(0), Registers.t(1)), // 18.75
		Opcode(&maxF32, Registers.t(5), Registers.t(1), Registers.t(0)),      // 7.5
		Opcode(&minF32, Registers.t(6), Registers.t(1), Registers.t(0)),      // 2.5

		Opcode(&setIfEqualF32, Registers.t(7), Registers.t(0), Registers.t(0)),
		Opcode(&setIfNotEqualF32, Registers.t(8), Registers.t(0), Registers.t(1)),
		Opcode(&setIfLessF32, Registers.t(9), Registers.t(1), Registers.t(0)),
		Opcode(&setIfGreaterEqualF32, Registers.t(10), Registers.t(0), Registers.t(1)),
		// ... and the same comparisons the other way, so both answers are seen.
		Opcode(&setIfEqualF32, Registers.t(11), Registers.t(0), Registers.t(1)),
		Opcode(&setIfNotEqualF32, Registers.t(12), Registers.t(0), Registers.t(0)),
		Opcode(&setIfLessF32, Registers.t(13), Registers.t(0), Registers.t(1)),
		Opcode(&setIfGreaterEqualF32, Registers.t(14), Registers.t(1), Registers.t(0)),

		// Integer <-> f32, unsigned and signed.
		Opcode(&loadImmediate, Registers.t(15)).setImmediate(9),
		Opcode(&convertToF32, Registers.t(16), Registers.t(15)),               // 9.0f
		Opcode(&convertFromF32, Registers.t(17), Registers.t(0)),              // 7
		Opcode(&loadImmediate, Registers.t(18)).setImmediateF32(-3.75f),
		Opcode(&convertSignedFromF32, Registers.t(19), Registers.t(18)),       // -3
		Opcode(&convertSignedToF32, Registers.t(18), Registers.t(19)),         // -3.0f
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	static float f32(ref RegistersAndStack e, Reg r) @trusted {
		return *cast(float*)&e.memory[r];
	}

	assert(f32(env, Registers.t(2)) == 10.0f);
	assert(f32(env, Registers.t(3)) == 5.0f);
	assert(f32(env, Registers.t(4)) == 18.75f);
	assert(f32(env, Registers.t(5)) == 7.5f);
	assert(f32(env, Registers.t(6)) == 2.5f);

	assert(env.memory[Registers.t(7)] == 1);
	assert(env.memory[Registers.t(8)] == 1);
	assert(env.memory[Registers.t(9)] == 1);
	assert(env.memory[Registers.t(10)] == 1);
	assert(env.memory[Registers.t(11)] == 0);
	assert(env.memory[Registers.t(12)] == 0);
	assert(env.memory[Registers.t(13)] == 0);
	assert(env.memory[Registers.t(14)] == 0);

	assert(f32(env, Registers.t(16)) == 9.0f);
	assert(env.memory[Registers.t(17)] == 7);
	assert(*cast(long*)&env.memory[Registers.t(19)] == -3);
	assert(f32(env, Registers.t(18)) == -3.0f);
}

unittest {
	// The `f64` arithmetic, conversions, comparisons and predicates. An f64
	// immediate does not fit in one opcode, so each constant is loaded as a
	// low half followed by an upper half.
	//
	// There are only 20 temporaries, so the results go in the argument
	// registers.
	static immutable Opcode[33] program = [
		Opcode(&loadImmediate, Registers.t(0)).setLowerImmediateF64(7.5),
		Opcode(&loadUpperImmediate, Registers.t(0)).setUpperImmediateF64(7.5),
		Opcode(&loadImmediate, Registers.t(1)).setLowerImmediateF64(2.5),
		Opcode(&loadUpperImmediate, Registers.t(1)).setUpperImmediateF64(2.5),
		Opcode(&loadImmediate, Registers.t(2)).setLowerImmediateF64(0.0),
		Opcode(&loadUpperImmediate, Registers.t(2)).setUpperImmediateF64(0.0),

		Opcode(&addF64, Registers.a(0), Registers.t(0), Registers.t(1)),      // 10.0
		Opcode(&subtractF64, Registers.a(1), Registers.t(0), Registers.t(1)), // 5.0
		Opcode(&maxF64, Registers.a(2), Registers.t(1), Registers.t(0)),      // 7.5
		Opcode(&minF64, Registers.a(3), Registers.t(1), Registers.t(0)),      // 2.5
		Opcode(&sqrtF64, Registers.a(4), Registers.a(1)),                     // sqrt(5)

		Opcode(&setIfEqualF64, Registers.a(5), Registers.t(0), Registers.t(0)),
		Opcode(&setIfNotEqualF64, Registers.a(6), Registers.t(0), Registers.t(1)),
		Opcode(&setIfLessF64, Registers.a(7), Registers.t(1), Registers.t(0)),
		Opcode(&setIfGreaterEqualF64, Registers.a(8), Registers.t(0), Registers.t(1)),
		// ... and the same comparisons the other way, so both answers are seen.
		Opcode(&setIfEqualF64, Registers.a(9), Registers.t(0), Registers.t(1)),
		Opcode(&setIfNotEqualF64, Registers.a(10), Registers.t(0), Registers.t(0)),
		Opcode(&setIfLessF64, Registers.a(11), Registers.t(0), Registers.t(1)),
		Opcode(&setIfGreaterEqualF64, Registers.a(12), Registers.t(1), Registers.t(0)),

		// nan and infinity, built the same way the f32 test builds them.
		Opcode(&divideF64, Registers.a(13), Registers.t(2), Registers.t(2)),  // nan
		Opcode(&divideF64, Registers.a(14), Registers.t(0), Registers.t(2)),  // +inf
		Opcode(&setIfNanF64, Registers.a(15), Registers.a(13)),
		Opcode(&setIfInfinityF64, Registers.a(16), Registers.a(14)),
		Opcode(&setIfNanF64, Registers.a(17), Registers.t(0)),
		Opcode(&setIfInfinityF64, Registers.a(18), Registers.t(0)),
		Opcode(&subtractF64, Registers.a(19), Registers.t(2), Registers.t(0)), // -7.5
		Opcode(&setIfNegativeF64, Registers.a(20), Registers.a(19)),
		Opcode(&setIfPositiveF64, Registers.a(21), Registers.t(0)),

		// The two widths convert into each other, and signed integers convert in.
		Opcode(&convertF64ToF32, Registers.a(22), Registers.t(0)),            // 7.5f
		Opcode(&convertF32ToF64, Registers.a(23), Registers.a(22)),           // 7.5
		Opcode(&convertSignedFromF64, Registers.a(24), Registers.a(19)),      // -7
		Opcode(&convertSignedToF64, Registers.a(25), Registers.a(24)),        // -7.0
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	static double f64(ref RegistersAndStack e, Reg r) @trusted {
		return *cast(double*)&e.memory[r];
	}

	assert(f64(env, Registers.a(0)) == 10.0);
	assert(f64(env, Registers.a(1)) == 5.0);
	assert(f64(env, Registers.a(2)) == 7.5);
	assert(f64(env, Registers.a(3)) == 2.5);
	immutable root = f64(env, Registers.a(4));
	assert(root * root - 5.0 < 1e-12 && 5.0 - root * root < 1e-12);

	assert(env.memory[Registers.a(5)] == 1);
	assert(env.memory[Registers.a(6)] == 1);
	assert(env.memory[Registers.a(7)] == 1);
	assert(env.memory[Registers.a(8)] == 1);
	assert(env.memory[Registers.a(9)] == 0);
	assert(env.memory[Registers.a(10)] == 0);
	assert(env.memory[Registers.a(11)] == 0);
	assert(env.memory[Registers.a(12)] == 0);

	assert(env.memory[Registers.a(15)] == 1); // nan is nan
	assert(env.memory[Registers.a(16)] == 1); // inf is inf
	assert(env.memory[Registers.a(17)] == 0); // 7.5 is not nan
	assert(env.memory[Registers.a(18)] == 0); // 7.5 is not infinite
	assert(env.memory[Registers.a(20)] == 1); // -7.5 is negative
	assert(env.memory[Registers.a(21)] == 1); // 7.5 is positive

	assert(*cast(float*)&env.memory[Registers.a(22)] == 7.5f);
	assert(f64(env, Registers.a(23)) == 7.5);
	assert(*cast(long*)&env.memory[Registers.a(24)] == -7);
	assert(f64(env, Registers.a(25)) == -7.0);
}

unittest {
	// The rest of the unsafe instructions: the fat pointer allocator, the
	// immediate forms of copy/set, and a pointer to the bottom of the stack.
	static immutable Opcode[24] program = [
		/*  0 */ Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),  // element size
		/*  1 */ Opcode(&loadImmediate, Registers.t(1)).setImmediate(4),  // element count
		/*  2 */ Opcode(&allocateFatPointer, Registers.t(2), Registers.t(0), Registers.t(1)),
		/*  3 */ Opcode(&loadImmediate, Registers.t(3)).setImmediate(0xFF),
		/*  4 */ Opcode(&loadImmediate, Registers.t(4)).setImmediate(32),
		/*  5 */ Opcode(&setMemory, Registers.t(2), Registers.t(3), Registers.t(4)),
		// Read the first 8 bytes back into t6, through a pointer to t6 itself.
		/*  6 */ Opcode(&pointerToRegister, Registers.t(5), Registers.t(6)),
		/*  7 */ Opcode(&copyMemoryImmediate, Registers.t(5), Registers.t(2), 8),
		// Then blank those same bytes with the immediate form and re-read.
		/*  8 */ Opcode(&loadImmediate, Registers.t(7)).setImmediate(0),
		/*  9 */ Opcode(&setMemoryImmediate, Registers.t(2), Registers.t(7), 8),
		/* 10 */ Opcode(&pointerToRegister, Registers.t(8), Registers.t(9)),
		/* 11 */ Opcode(&copyMemoryImmediate, Registers.t(8), Registers.t(2), 8),
		/* 12 */ Opcode(&freeFatPointer, 0, Registers.t(2), 0),

		// pointerToStackBottom addresses the same byte stackStoreU64 wrote.
		/* 13 */ Opcode(&loadImmediate, Registers.t(10)).setImmediate(16),
		/* 14 */ Opcode(&stackPush, 0, Registers.t(10)),   // sp = bottom - 16
		/* 15 */ Opcode(&loadImmediate, Registers.t(11)).setImmediate(0xBEEF),
		/* 16 */ Opcode(&loadImmediate, Registers.t(12)).setImmediate(8),
		/* 17 */ Opcode(&stackStoreU64, 0, Registers.t(11), Registers.t(12)), // bottom - 8
		/* 18 */ Opcode(&loadImmediate, Registers.t(13)).setImmediate(8),
		/* 19 */ Opcode(&pointerToStackBottom, Registers.t(14), Registers.t(13)),
		/* 20 */ Opcode(&pointerToRegister, Registers.t(15), Registers.t(16)),
		/* 21 */ Opcode(&copyMemory, Registers.t(15), Registers.t(14), Registers.t(0)),
		/* 22 */ Opcode(&stackPop, 0, Registers.t(10)),
		/* 23 */ Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(6)] == ulong.max); // setMemory filled it
	assert(env.memory[Registers.t(9)] == 0);         // setMemoryImmediate blanked it
	assert(env.memory[Registers.t(2)] == 0);         // freeFatPointer cleared the handle
	assert(env.memory[Registers.t(16)] == 0xBEEF);   // via pointerToStackBottom
}

unittest {
	// The two relative `fork` instructions, each starting a worker that
	// reports back down a shared channel.
	static immutable Opcode[17] program = [
		/*  0 */ Opcode(&loadImmediate, Registers.t(0)).setImmediate(2),
		/*  1 */ Opcode(&channelCreate, 220, Registers.t(0)),
		/*  2 */ Opcode(&loadImmediate, Registers.t(1)).setImmediate(8),
		/*  3 */ Opcode(&forkRelative, 221, Registers.t(1)),                 // -> 11
		/*  4 */ Opcode(&forkRelativeImmediate, 222).setImmediateSigned(10), // -> 14
		/*  5 */ Opcode(&channelReceive, 223, 220),
		/*  6 */ Opcode(&channelReceive, 224, 220),
		/*  7 */ Opcode(&joinThread, 0, 221, 0),
		/*  8 */ Opcode(&joinThread, 0, 222, 0),
		/*  9 */ Opcode(&channelClose, 0, 220, 0),
		/* 10 */ Opcode(&halt),

		// worker A
		/* 11 */ Opcode(&loadImmediate, Registers.t(2)).setImmediate(11),
		/* 12 */ Opcode(&channelSend, 0, 220, Registers.t(2)),
		/* 13 */ Opcode(&halt),
		// worker B
		/* 14 */ Opcode(&loadImmediate, Registers.t(3)).setImmediate(22),
		/* 15 */ Opcode(&channelSend, 0, 220, Registers.t(3)),
		/* 16 */ Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	// The two workers race, so only the pair of values is determined.
	immutable first = env.memory[223], second = env.memory[224];
	assert((first == 11 && second == 22) || (first == 22 && second == 11));
	assert(env.memory[221] == 0); // joinThread cleared both handles
	assert(env.memory[222] == 0);
	assert(env.memory[220] == 0); // channelClose cleared the channel
}

unittest {
	// The blocking (rather than "try") mutex locks. Nothing else holds this
	// mutex, so each lock is taken immediately.
	static immutable Opcode[7] program = [
		Opcode(&mutexCreate, Registers.t(0)),
		Opcode(&mutexWriteLock, 0, Registers.t(0)),
		Opcode(&mutexWriteUnlock, 0, Registers.t(0)),
		Opcode(&mutexReadLock, 0, Registers.t(0)),
		Opcode(&mutexReadUnlock, 0, Registers.t(0)),
		Opcode(&mutexFree, 0, Registers.t(0), 0),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);
	assert(env.memory[Registers.t(0)] == 0); // mutexFree cleared the handle
}

unittest {
	// Every remaining `pushType*`, emptied again with `clearTypeStack` so the
	// stack is left the way the other FFI tests expect to find it.
	import mizu.ffi;

	static immutable Opcode[9] program = [
		Opcode(&pushTypeU32),
		Opcode(&pushTypeI64),
		Opcode(&pushTypeU64),
		Opcode(&pushTypeF32),
		Opcode(&pushTypeF64),
		Opcode(&pushTypeVoid),
		Opcode(&pushTypePointer),
		Opcode(&clearTypeStack),
		Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);
}

unittest {
	// A foreign call taking and returning `int32_t`: mizuTestNegate(-5).
	import mizu.ffi;

	static immutable char[16] symbol = "mizuTestNegate\0\0";

	Opcode[10] program = [
		Opcode(&pushTypeI32), // return type
		Opcode(&pushTypeI32), // argument type
		Opcode(&createInterface, 201),
		Opcode(&loadImmediate, 203).setHostPointerLowerImmediate(symbol.ptr),
		Opcode(&loadUpperImmediate, 203).setHostPointerUpperImmediate(symbol.ptr),
		Opcode(&loadLibraryFunction, 202, 0, 203),
		Opcode(&loadImmediate, Registers.a(0)).setImmediate(0xFFFFFFFB), // -5 as i32
		Opcode(&callWithReturn, Registers.t(0), 202, 201),
		Opcode(&freeInterface, 0, 201, 0),
		Opcode(&halt),
	];

	RegistersAndStack env;
	setupEnvironment(env, program[]);
	startFromEnvironment(program[], env);

	assert(env.memory[202] != 0);                        // Found the function.
	assert(cast(int) env.memory[Registers.t(0)] == 5);   // And it changed the sign.
	assert(env.memory[201] == 0);                        // freeInterface cleared it.
}

unittest {
	// The two library-loading instructions: one name that cannot resolve, and
	// a list in which the C library is found under whichever name fits.
	//
	// Every platform has a C library under one of these names, and neither
	// spelling is a path, so this also exercises the loader's search rather
	// than just opening a file.
	import mizu.ffi;

	version(Windows) {
		static immutable char[7] first = "msvcrt\0";
		static immutable char[9] second = "ucrtbase\0";
	} else {
		static immutable char[10] first = "libc.so.6\0";
		static immutable char[18] second = "libSystem.B.dylib\0";
	}
	static immutable char[32] missing = "mizu_definitely_not_a_library\0\0\0";

	Opcode[10] program = [
		Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(first.ptr),
		Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(first.ptr),
		Opcode(&loadImmediate, Registers.a(1)).setHostPointerLowerImmediate(second.ptr),
		Opcode(&loadUpperImmediate, Registers.a(1)).setHostPointerUpperImmediate(second.ptr),
		Opcode(&loadFirstLibraryThatExists, Registers.t(0)).setImmediate(2),

		Opcode(&loadImmediate, Registers.t(1)).setHostPointerLowerImmediate(missing.ptr),
		Opcode(&loadUpperImmediate, Registers.t(1)).setHostPointerUpperImmediate(missing.ptr),
		Opcode(&loadLibrary, Registers.t(2), Registers.t(1)),
		Opcode(&halt),
		Opcode(&halt),
	];

	RegistersAndStack env;
	setupEnvironment(env, program[]);
	startFromEnvironment(program[], env);

	assert(env.memory[Registers.t(0)] != 0); // One of the two names loaded.
	assert(env.memory[Registers.t(2)] == 0); // And the nonexistent one did not.

	close(cast(Library*) env.memory[Registers.t(0)]);
}

unittest {
	// An interface has to describe at least a return type, so building one
	// from an empty type stack is fatal.
	import mizu.ffi;

	static immutable Opcode[3] program = [
		Opcode(&clearTypeStack),
		Opcode(&createInterface, 201),
		Opcode(&halt),
	];

	RegistersAndStack env;
	assert(aborts({ run(program[], env); }));
}

unittest {
	// A foreign call reads its arguments straight out of the argument
	// registers into a fixed array of 128 pointers, so a signature wider than
	// that is fatal — before the function pointer (here, null) is ever used.
	import mizu.ffi;

	enum size_t argumentCount = 129;
	Opcode[argumentCount + 5] program;
	program[0] = Opcode(&clearTypeStack);
	program[1] = Opcode(&pushTypeU64); // the return type
	foreach (i; 0 .. argumentCount)
		program[2 + i] = Opcode(&pushTypeU64);
	program[2 + argumentCount] = Opcode(&createInterface, 201);
	program[3 + argumentCount] = Opcode(&call, 0, 0, 201);
	program[4 + argumentCount] = Opcode(&halt);

	RegistersAndStack env;
	assert(aborts({ run(program[], env); }));
}

static if (noHardwareThreads)
unittest {
	// The coroutine scheduler's back-pressure, which only shows up when two
	// contexts really do compete: a `channelSend` to a channel that is
	// already full, and a `joinThread` on a context that has not halted yet.
	// Both rewind their program counter and yield rather than blocking, so
	// the only way to reach them is to make the other context late.
	//
	// The channel holds one value. The worker idles for a few instructions
	// before its first receive, which is long enough for the main context to
	// fill the channel and find its second send with nowhere to put a value.
	// Contexts alternate one instruction at a time, so this is deterministic
	// rather than a race.
	enum Reg data = 220, worker = 221, results = 222;
	enum Opcode nop = Opcode(&add, 0, 0, 0); // Writes x0, which stays zero.

	static immutable Opcode[27] program = [
		/*  0 */ Opcode(&findLabel, 200).setImmediate(label2immediate("wrk")),
		/*  1 */ Opcode(&loadImmediate, Registers.t(0)).setImmediate(1), // capacity
		/*  2 */ Opcode(&channelCreate, data, Registers.t(0)),
		/*  3 */ Opcode(&channelCreate, results, Registers.t(0)),
		/*  4 */ Opcode(&forkTo, worker, 200),
		// Three values down a one-deep channel.
		/*  5 */ Opcode(&loadImmediate, Registers.t(1)).setImmediate(11),
		/*  6 */ Opcode(&channelSend, 0, data, Registers.t(1)),
		/*  7 */ Opcode(&loadImmediate, Registers.t(1)).setImmediate(22),
		/*  8 */ Opcode(&channelSend, 0, data, Registers.t(1)),
		/*  9 */ Opcode(&loadImmediate, Registers.t(1)).setImmediate(33),
		/* 10 */ Opcode(&channelSend, 0, data, Registers.t(1)),
		// Join before reading the answer, so the join has something to wait on.
		/* 11 */ Opcode(&joinThread, 0, worker, 0),
		/* 12 */ Opcode(&channelReceive, Registers.t(2), results),
		/* 13 */ Opcode(&channelClose, 0, data, 0),
		/* 14 */ Opcode(&channelClose, 0, results, 0),
		/* 15 */ Opcode(&halt),

		// wrk: dawdle, then drain the channel and send back the total.
		/* 16 */ Opcode(&label).setImmediate(label2immediate("wrk")),
		/* 17 */ nop,
		/* 18 */ nop,
		/* 19 */ nop,
		/* 20 */ Opcode(&channelReceive, Registers.t(3), data),
		/* 21 */ Opcode(&channelReceive, Registers.t(4), data),
		/* 22 */ Opcode(&channelReceive, Registers.t(5), data),
		/* 23 */ Opcode(&add, Registers.t(6), Registers.t(3), Registers.t(4)),
		/* 24 */ Opcode(&add, Registers.t(6), Registers.t(6), Registers.t(5)),
		/* 25 */ Opcode(&channelSend, 0, results, Registers.t(6)),
		/* 26 */ Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	// Every value crossed the channel, in order, despite it never holding
	// more than one of them at a time.
	assert(env.memory[Registers.t(2)] == 11 + 22 + 33);
	assert(env.memory[worker] == 0);  // joinThread cleared the handle.
	assert(env.memory[data] == 0);    // And both channels are closed.
	assert(env.memory[results] == 0);
}

static if (noHardwareThreads)
unittest {
	// The failing half of the coroutine try-locks. With the fallback the
	// lock state is the register itself, so a context can watch its own
	// mutex refuse a second lock; with hardware threads the same program
	// would relock a `pthread_rwlock` it already holds, which POSIX leaves
	// undefined, hence the `static if`.
	static immutable Opcode[10] program = [
		/* 0 */ Opcode(&mutexCreate, Registers.t(0)),
		/* 1 */ Opcode(&mutexTryWriteLock, Registers.t(1), Registers.t(0)),
		// Write locked, so neither lock can be taken now.
		/* 2 */ Opcode(&mutexTryWriteLock, Registers.t(2), Registers.t(0)),
		/* 3 */ Opcode(&mutexTryReadLock, Registers.t(3), Registers.t(0)),
		/* 4 */ Opcode(&mutexWriteUnlock, 0, Registers.t(0)),
		// Read locked, which still excludes a writer.
		/* 5 */ Opcode(&mutexTryReadLock, Registers.t(4), Registers.t(0)),
		/* 6 */ Opcode(&mutexTryWriteLock, Registers.t(5), Registers.t(0)),
		/* 7 */ Opcode(&mutexReadUnlock, 0, Registers.t(0)),
		/* 8 */ Opcode(&mutexFree, 0, Registers.t(0), 0),
		/* 9 */ Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[Registers.t(1)] == 1); // Took the write lock.
	assert(env.memory[Registers.t(2)] == 0); // Second writer refused.
	assert(env.memory[Registers.t(3)] == 0); // And so is a reader.
	assert(env.memory[Registers.t(4)] == 1); // Once unlocked, a reader fits.
	assert(env.memory[Registers.t(5)] == 0); // But a writer still does not.
	assert(env.memory[Registers.t(0)] == 0); // mutexFree cleared the handle.
}

static if (noHardwareThreads)
unittest {
	// The blocking halves of the coroutine locks: `mutexWriteLock` and
	// `mutexReadLock` finding the lock already held, rewinding and yielding.
	//
	// With the fallback there is no OS mutex — the register itself is the lock
	// state — and forking copies the whole register file, so a second context
	// cannot release what the first holds through the mutex instructions (see
	// the note on `mutexCreate`). What it can do is write to the first
	// context's register file directly: `pointerToRegister` takes the address
	// of the lock register before the fork, so the worker inherits a pointer
	// to the *main* context's copy and can clear it.
	//
	// Contexts alternate one instruction at a time, so the interleaving below
	// is deterministic rather than a race. Reading down the two columns:
	//
	//   main 5 blocks [w] | wrk 13 clears | main 5 takes it | wrk 14 idles
	//   main 6 blocks [r] | wrk 15 clears | main 6 takes it | wrk 16 halts
	enum Reg lock = Registers.t(0), address = Registers.t(1);
	enum Reg witness = Registers.t(2), worker = 220;
	enum Opcode nop = Opcode(&add, 0, 0, 0); // Writes x0, which stays zero.

	static immutable Opcode[17] program = [
		/*  0 */ Opcode(&findLabel, 200).setImmediate(label2immediate("wrk")),
		/*  1 */ Opcode(&pointerToRegister, address, lock),
		/*  2 */ Opcode(&mutexCreate, lock),
		/*  3 */ Opcode(&mutexWriteLock, 0, lock), // Uncontended: taken at once.
		/*  4 */ Opcode(&forkTo, worker, 200),
		// Both of these find the lock held and have to wait for the worker.
		/*  5 */ Opcode(&mutexWriteLock, 0, lock),
		/*  6 */ Opcode(&mutexReadLock, 0, lock),
		/*  7 */ Opcode(&loadImmediate, witness).setImmediate(1),
		/*  8 */ Opcode(&joinThread, 0, worker, 0),
		/*  9 */ Opcode(&mutexReadUnlock, 0, lock),
		/* 10 */ Opcode(&mutexFree, 0, lock, 0),
		/* 11 */ Opcode(&halt),

		// wrk: clear the main context's lock register, twice, spaced so that
		// each clear lands while main is waiting rather than before it starts.
		/* 12 */ Opcode(&label).setImmediate(label2immediate("wrk")),
		/* 13 */ Opcode(&setMemoryImmediate, address, 0, 8),
		/* 14 */ nop,
		/* 15 */ Opcode(&setMemoryImmediate, address, 0, 8),
		/* 16 */ Opcode(&halt),
	];

	RegistersAndStack env;
	run(program[], env);

	assert(env.memory[witness] == 1); // Both blocking locks eventually returned.
	assert(env.memory[worker] == 0);  // joinThread cleared the handle.
	assert(env.memory[lock] == 0);    // mutexFree cleared the lock register.
}
