/**
* The D port of the C++ `tests/fib.cpp`: recursive Fibonacci, computed by a
* Mizu program that saves and restores registers on Mizu's own stack.
*
* Run with: `dub run -c example-fib --compiler=ldc2`
*/
module examples.fib;

import core.stdc.stdio : printf;

import mizu;

enum uint target = 30;

/// Everything up to restoring `a2`; split only to keep the literals readable.
immutable Opcode[32] fibHead = [
	Opcode(&findLabel, 200).setImmediate(label2immediate("fib")),
	// a0 = target, then a0 = fib(a0)
	Opcode(&loadImmediate, Registers.a(0)).setImmediate(target),
	Opcode(&jumpTo, Registers.ra, 200),
	Opcode(&debugPrint, 0, Registers.a(0)),
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

/// Ditto
immutable Opcode[4] fibTail = [
	Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
	Opcode(&stackLoadU64, Registers.a(3), Registers.t(0)),
	Opcode(&stackPopImmediate).setImmediate(24),
	Opcode(&jumpTo, 0, Registers.ra), // return
];

immutable Opcode[36] program = fibHead ~ fibTail;

extern(C) int main() {
	printf("fib(%u) = ", target);

	RegistersAndStack environment;
	setupEnvironment(environment, program[]);
	startFromEnvironment(program[], environment);

	return 0;
}
