/**
* `-betterC` has no built-in unittest runner, so this walks every module's tests with `__traits(getUnitTests)` and calls them.
*
* Progress goes to `stderr`, which is unbuffered, so a test that hangs or aborts still leaves a record of how far the run got.
*/
module runner;

import core.stdc.stdio : fprintf, printf, stderr;

private enum modules = [
	"mizu.error",
	"mizu.opcode",
	"mizu.instructions.core",
	"mizu.instructions.parallel",
	"mizu.lookup",
	"mizu.serialize",
	"mizu.portable_format",
	"mizu.ffi.loader",
	"vm_tests",
];

private int runEveryTest() {
	size_t total = 0;

	static foreach (name; modules) {{
		alias mod = mixin("imported!\"" ~ name ~ "\"");
		alias tests = __traits(getUnitTests, mod);
		cast(void) fprintf(stderr, "%s (%d tests)\n", name.ptr, cast(int) tests.length);
		static foreach (i, test; tests) {
			cast(void) fprintf(stderr, "  [%d] ", cast(int) i);
			test();
			cast(void) fprintf(stderr, "ok\n");
			++total;
		}
	}}

	cast(void) printf("All %d tests passed.\n", cast(int) total);
	return 0;
}

// `tools/coverage.py` builds ordinary D, since `-cov` registers its counters through druntime, which needs its own `main` to run.
version(MizuCoverage) {
	// A tester that runs nothing but still asks for `main`, so druntime does not run every test before `runEveryTest` does.
	shared static this() {
		import core.runtime : Runtime, UnitTestResult;
		Runtime.extendedModuleUnitTester = () => UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }
