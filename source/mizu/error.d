/**
* `-betterC` has no exceptions, so where the C++ original threw, Mizu prints a diagnostic to `stderr` and aborts, through `fatal`.
*/
module mizu.error;

static import fp.io;

@nogc nothrow:

// wrapper: Mizu's one spelling of an unrecoverable VM error, so every report reads `mizu: fatal: …`
/**
* Reports an unrecoverable VM error on stderr and aborts the process, through `fp.io.abort`.
* The message is slices, characters and integers, such as a detail appended to the text.
*
* Examples:
* ---
* static void check(bool ok, long detail) @nogc nothrow {
* 	if (!ok) fatal("check failed: ", detail);
* }
* check(true, 0);
* ---
*/
noreturn fatal(Pieces...)(Pieces message) {
	fp.io.abort("mizu: fatal: ", message, '\n');
}

unittest {
	static import fp.testing;
	static if (fp.testing.catchesAborts) {
		assert(fp.testing.aborts(() { fatal("unit test"); }));
		assert(fp.testing.aborts(() { fatal("unit test, detail = ", 42); }));
	}
}
