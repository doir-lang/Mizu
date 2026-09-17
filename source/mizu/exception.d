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

/*
* Watching `fatal` happen from inside the process it ends means catching the
* `SIGABRT` that `abort` raises and jumping back out of the handler. The two
* platforms differ only in how the jump buffer is spelled and how a handler is
* installed; the test below is otherwise shared.
*/
version(Posix) {
	// druntime declares `sigjmp_buf` as a static array, which D passes to an
	// `extern(C)` function by value rather than decaying to a pointer the way
	// C does, so the jump buffer these get is a copy. Bind them by pointer.
	// It does not declare it at all on Darwin, and where it does the layout
	// is the C library's business rather than ours, so the buffer below is a
	// reserve large enough for every one of them instead of that type.
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
} else version(Windows) {
	// The MS C runtime calls a `SIGABRT` handler as an ordinary function from
	// inside `abort` rather than through the operating system's signal
	// machinery, so leaving it is an ordinary `longjmp`. `jmp_buf`'s layout is
	// not ours to know — 256 bytes on x86-64, less elsewhere — hence the
	// generous reserve, and handing `_setjmp` a null frame is the documented
	// way to ask for a plain register restore rather than an SEH unwind.
	private extern(C) @nogc nothrow {
		int _setjmp(void* buffer, void* frame);
		void longjmp(void* buffer, int value);
	}

	// `core.stdc.signal` declares `signal` without `@nogc nothrow`, which this
	// module is, so bind it here instead. `SIGABRT` is 22 on Windows.
	private alias AbortHandler = extern(C) void function(int) @nogc nothrow;
	private extern(C) @nogc nothrow AbortHandler signal(int sig, AbortHandler handler);
	private enum int windowsSigabrt = 22;
}

unittest {
	// `fatal` ends the process, so the only way to watch it happen from
	// inside that process is to catch the `SIGABRT` it raises and jump back
	// out of the handler. On POSIX `abort` unblocks the signal before raising
	// it and `sigsetjmp`/`siglongjmp` save and restore the mask, so once the
	// old handler is back the process is exactly as it was found; Windows has
	// no mask to keep, and puts its handler back by hand instead.

	// The handler counts its arrivals, so the assertions below rest on
	// `SIGABRT` actually having been raised. A flag set on the way *into*
	// `fatal` would prove only that the call was reached, and one set on the
	// way out is dead code the compiler drops, `fatal` being `noreturn`.
	__gshared int aborts;

	version(Posix) {
		import core.sys.posix.signal : sigaction_t, sigaction, sigemptyset, SIGABRT;

		__gshared align(16) ubyte[1024] escape;
		static extern(C) void onAbort(int) @nogc nothrow {
			++aborts;
			siglongjmp(escape.ptr, 1);
		}

		sigaction_t action, previous;
		sigemptyset(&action.sa_mask);
		action.sa_handler = &onAbort;
		sigaction(SIGABRT, &action, &previous);
	} else version(Windows) {
		__gshared align(16) ubyte[512] escape;
		static extern(C) void onAbort(int) @nogc nothrow {
			++aborts;
			// Windows resets a handler to the default as it raises, so the
			// second `fatal` below would otherwise go uncaught.
			signal(windowsSigabrt, &onAbort);
			longjmp(escape.ptr, 1);
		}

		auto previous = signal(windowsSigabrt, &onAbort);
	}

	// `setjmp` records the frame it was called from, so both calls have to be
	// made from here rather than from a helper that would have returned
	// before the jump arrived.
	version(Posix) {
		if (sigsetjmpByPointer(escape.ptr, 1) == 0)
			fatal("unit test");

		if (sigsetjmpByPointer(escape.ptr, 1) == 0)
			fatal("unit test, detail = ", 42);

		sigaction(SIGABRT, &previous, null);
	} else version(Windows) {
		if (_setjmp(escape.ptr, null) == 0)
			fatal("unit test");

		if (_setjmp(escape.ptr, null) == 0)
			fatal("unit test, detail = ", 42);

		signal(windowsSigabrt, previous);
	}

	// Both overloads aborted, and both landed back at their `setjmp`.
	assert(aborts == 2);
}
