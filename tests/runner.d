/**
* `-betterC` has no built-in unittest runner, so this walks every module's tests with `__traits(getUnitTests)` and calls them.
*
* Progress goes to `stderr`, which is unbuffered, so a test that hangs or aborts still leaves a record of how far the run got.
*/
module runner;

private alias modules = imported!"std.meta".AliasSeq!(
	"mizu.error",
	"mizu.opcode",
	"mizu.instructions.core",
	"mizu.instructions.parallel",
	"mizu.lookup",
	"mizu.serialize",
	"mizu.portable_format",
	"mizu.ffi.loader",
	"mizu.ffi.trampoline",
	"vm_tests",
);

private int runEveryTest() {
	cast(void) imported!"fp.testing".runTests!modules("mizu");
	return 0;
}

// `tools/coverage.py` builds ordinary D, since `-cov` registers its counters through druntime, which needs its own `main` to run.
version(MizuCoverage) {
	// A tester that runs nothing but still asks for `main`, so druntime does not run every test before `runEveryTest` does.
	shared static this() {
		static import core.runtime;
		core.runtime.Runtime.extendedModuleUnitTester = () => core.runtime.UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }
