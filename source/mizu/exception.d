/**
* `-betterC` has no exceptions, so the C++ `MIZU_THROW` macro becomes a
* diagnostic printed to `stderr` followed by `abort()`. Everything that used
* to `throw std::runtime_error` now calls `fatal`.
*/
module mizu.exception;

import core.stdc.stdio : fprintf, stderr;
import core.stdc.stdlib : abort;

@nogc nothrow:

/// Reports an unrecoverable VM error and aborts the process.
noreturn fatal(scope const(char)* message) @trusted {
	fprintf(stderr, "mizu: fatal: %s\n", message);
	abort();
	assert(0);
}

/// Ditto, with one integer detail appended.
noreturn fatal(scope const(char)* message, long detail) @trusted {
	fprintf(stderr, "mizu: fatal: %s%ld\n", message, detail);
	abort();
	assert(0);
}

version(Posix) {
	// druntime declares `sigjmp_buf` as a static array, which D passes to an
	// `extern(C)` function by value rather than decaying to a pointer the way
	// C does, so the jump buffer these get is a copy. Bind them by pointer.
	//
	// glibc and uClibc export only `__sigsetjmp`, their `sigsetjmp` being a
	// macro around it. Everywhere else — musl, Bionic, macOS, the BSDs — it
	// is an ordinary function under its own name.
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
}

version(Posix)
unittest {
	// `fatal` ends the process, so the only way to watch it happen from
	// inside that process is to catch the `SIGABRT` it raises and jump back
	// out of the handler. `abort` unblocks the signal before raising it and
	// `sigsetjmp`/`siglongjmp` save and restore the mask, so once the old
	// handler is back the process is exactly as it was found.
	import core.sys.posix.setjmp : sigjmp_buf;
	import core.sys.posix.signal : sigaction_t, sigaction, sigemptyset, SIGABRT;

	// The handler counts its arrivals, so the assertions below rest on
	// `SIGABRT` actually having been raised. A flag set on the way *into*
	// `fatal` would prove only that the call was reached, and one set on the
	// way out is dead code the compiler drops, `fatal` being `noreturn`.
	__gshared sigjmp_buf escape;
	__gshared int aborts;
	static extern(C) void onAbort(int) @nogc nothrow {
		++aborts;
		siglongjmp(escape.ptr, 1);
	}

	sigaction_t action, previous;
	sigemptyset(&action.sa_mask);
	action.sa_handler = &onAbort;
	sigaction(SIGABRT, &action, &previous);

	if (sigsetjmpByPointer(escape.ptr, 1) == 0)
		fatal("unit test");

	if (sigsetjmpByPointer(escape.ptr, 1) == 0)
		fatal("unit test, detail = ", 42);

	sigaction(SIGABRT, &previous, null);

	// Both overloads aborted, and both landed back at their `sigsetjmp`.
	assert(aborts == 2);
}
