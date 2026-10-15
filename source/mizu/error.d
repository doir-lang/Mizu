/**
* `-betterC` has no exceptions, so where the C++ original threw, Mizu prints a diagnostic to `stderr` and aborts, through `fatal`.
*/
module mizu.error;

import core.stdc.stdio : fprintf, stderr;
import core.stdc.stdlib : abort;

@nogc nothrow:

/**
* Reports an unrecoverable VM error on stderr and aborts the process.
*
* Examples:
* ---
* static void check(bool ok) @nogc nothrow {
* 	if (!ok) fatal("check failed");
* }
* check(true);
* ---
*/
noreturn fatal(scope const(char)* message) @trusted {
	cast(void) fprintf(stderr, "mizu: fatal: %s\n", message);
	abort();
	assert(0);
}

/// Ditto, with one integer detail appended.
noreturn fatal(scope const(char)* message, long detail) @trusted {
	cast(void) fprintf(stderr, "mizu: fatal: %s%lld\n", message, detail);
	abort();
	assert(0);
}

// Watching `fatal` from inside the process it ends means catching `abort`'s `SIGABRT` and jumping back out of the handler; on WASI `abort` traps, which nothing can catch.
version(WASI) {} else version(Posix) {
	// druntime passes `sigjmp_buf` by value and lacks it on Darwin, so these take an oversized buffer by pointer.

	// glibc and uClibc export only `__sigsetjmp`, their `sigsetjmp` being a macro around it.
	version(CRuntime_Glibc) version = MizuUnderscoredSigsetjmp;
	else version(CRuntime_UClibc) version = MizuUnderscoredSigsetjmp;

	version(MizuUnderscoredSigsetjmp) {
		private extern(C) int __sigsetjmp(void* buffer, int saveMask);
		private alias sigsetjmpByPointer = __sigsetjmp;
	} else {
		private extern(C) int sigsetjmp(void* buffer, int saveMask);
		private alias sigsetjmpByPointer = sigsetjmp;
	}

	private extern(C) void siglongjmp(void* buffer, int value);
} else version(Windows) {
	// The MS C runtime calls a `SIGABRT` handler directly from `abort`, so a plain `longjmp` leaves it; a null frame skips SEH unwinding.
	private extern(C) {
		int _setjmp(void* buffer, void* frame);
		void longjmp(void* buffer, int value);
	}

	// `core.stdc.signal` declares `signal` without `@nogc nothrow`, so bind it here. `SIGABRT` is 22 on Windows.
	private alias AbortHandler = extern(C) void function(int) @nogc nothrow;
	private extern(C) AbortHandler signal(int sig, AbortHandler handler);
	private enum int windowsSigabrt = 22;
}

version(WASI) {} else unittest {
	// The handler counts arrivals, proving `SIGABRT` was really raised; POSIX restores the mask with `siglongjmp`, Windows reinstalls its handler.
	__gshared int aborts;

	version(Posix) {
		import core.sys.posix.signal : sigaction_t, sigaction, sigemptyset, SIGABRT;

		__gshared align(16) ubyte[1024] escape;
		static extern(C) void onAbort(int) @nogc nothrow {
			++aborts;
			siglongjmp(escape.ptr, 1);
		}

		sigaction_t action, previous;
		assert(sigemptyset(&action.sa_mask) == 0);
		action.sa_handler = &onAbort;
		assert(sigaction(SIGABRT, &action, &previous) == 0);
	} else version(Windows) {
		__gshared align(16) ubyte[512] escape;
		static extern(C) void onAbort(int) @nogc nothrow {
			++aborts;
			// Windows resets a handler to the default as it raises, so the second `fatal` would otherwise go uncaught.
			cast(void) signal(windowsSigabrt, &onAbort);
			longjmp(escape.ptr, 1);
		}

		auto previous = signal(windowsSigabrt, &onAbort);
	}

	// `setjmp` records the frame it was called from, so both calls must be made here rather than from a helper.
	version(Posix) {
		if (sigsetjmpByPointer(escape.ptr, 1) == 0)
			fatal("unit test");

		if (sigsetjmpByPointer(escape.ptr, 1) == 0)
			fatal("unit test, detail = ", 42);

		assert(sigaction(SIGABRT, &previous, null) == 0);
	} else version(Windows) {
		if (_setjmp(escape.ptr, null) == 0)
			fatal("unit test");

		if (_setjmp(escape.ptr, null) == 0)
			fatal("unit test, detail = ", 42);

		cast(void) signal(windowsSigabrt, previous);
	}

	// Both overloads aborted, and both landed back at their `setjmp`.
	assert(aborts == 2);
}
