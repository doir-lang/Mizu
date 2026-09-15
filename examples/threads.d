/**
* The D port of the C++ `tests/test.cpp`: a Mizu program that forks a thread,
* has that thread call a host function through the FFI and compute Fibonacci
* recursively, and passes the answer back over a channel.
*
* Run with: `dub run -c example-threads --compiler=ldc2`
*/
module examples.threads;

import core.stdc.stdio : printf;

import mizu;
import mizu.ffi;

/// The host function the Mizu program calls through the FFI.
export extern(C) void mizuExamplePrint(const(char)* text) @nogc nothrow {
	printf("[host] %s\n", text);
}

immutable char[7] greeting = "Hello\0";
immutable char[19] symbolName = "mizuExamplePrint\0";

extern(C) int main() {
	// Host pointers are only known at run time, so this program is built here
	// rather than being a compile-time constant.
	Opcode[57] program = [
		Opcode(&findLabel, 200).setImmediate(label2immediate("thrd")),

		// Describe void mizuExamplePrint(void*) and find the function.
		Opcode(&pushTypeVoid),
		Opcode(&pushTypePointer),
		Opcode(&createInterface, 201),
		Opcode(&loadImmediate, 205).setHostPointerLowerImmediate(symbolName.ptr),
		Opcode(&loadUpperImmediate, 205).setHostPointerUpperImmediate(symbolName.ptr),
		Opcode(&loadLibraryFunction, 203, 0, 205),
		Opcode(&loadImmediate, 204).setHostPointerLowerImmediate(greeting.ptr),
		Opcode(&loadUpperImmediate, 204).setHostPointerUpperImmediate(greeting.ptr),

		// A single-slot channel, then fork the worker.
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
		Opcode(&channelCreate, 220, Registers.t(0)),
		Opcode(&forkTo, 221, 200),

		// Wait for the worker's answer, tidy up, and print it.
		Opcode(&channelReceive, 222, 220),
		Opcode(&joinThread, 0, 221, 0),
		Opcode(&channelClose, 0, 220, 0),
		Opcode(&freeInterface, 0, 201, 0),
		Opcode(&debugPrint, 0, 222),
		Opcode(&halt),

		// The worker thread.
		Opcode(&label).setImmediate(label2immediate("thrd")),
		Opcode(&findLabel, 202).setImmediate(label2immediate("fib")),
		// mizuExamplePrint(greeting)
		Opcode(&add, Registers.a(0), 204, 0),
		Opcode(&call, 0, 203, 201),
		// a0 = fib(25)
		Opcode(&loadImmediate, Registers.a(0)).setImmediate(25),
		Opcode(&jumpTo, Registers.ra, 202),
		Opcode(&channelSend, 0, 220, Registers.a(0)),
		Opcode(&halt),

		// Recursive Fibonacci, as in examples/fib.d.
		Opcode(&label).setImmediate(label2immediate("fib")),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(3),
		Opcode(&setIfGreaterEqual, Registers.t(0), Registers.a(0), Registers.t(0)),
		Opcode(&branchRelativeImmediate, 0, Registers.t(0)).setBranchImmediate(3),
		Opcode(&loadImmediate, Registers.a(0)).setImmediate(1),
		Opcode(&jumpTo, 0, Registers.ra),
		Opcode(&stackPushImmediate, 0).setImmediate(24),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(24),
		Opcode(&stackStoreU64, 0, Registers.ra, Registers.t(0)),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(16),
		Opcode(&stackStoreU64, 0, Registers.a(2), Registers.t(0)),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
		Opcode(&stackStoreU64, 0, Registers.a(3), Registers.t(0)),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
		Opcode(&subtract, Registers.a(2), Registers.a(0), Registers.t(0)),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(2),
		Opcode(&subtract, Registers.a(3), Registers.a(0), Registers.t(0)),
		Opcode(&add, Registers.a(0), Registers.a(2), 0),
		Opcode(&jumpTo, Registers.ra, 202),
		Opcode(&add, Registers.a(2), Registers.a(0), 0),
		Opcode(&add, Registers.a(0), Registers.a(3), 0),
		Opcode(&jumpTo, Registers.ra, 202),
		Opcode(&add, Registers.a(0), Registers.a(2), Registers.a(0)),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(24),
		Opcode(&stackLoadU64, Registers.ra, Registers.t(0)),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(16),
		Opcode(&stackLoadU64, Registers.a(2), Registers.t(0)),
		Opcode(&loadImmediate, Registers.t(0)).setImmediate(8),
		Opcode(&stackLoadU64, Registers.a(3), Registers.t(0)),
		Opcode(&stackPopImmediate).setImmediate(24),
		Opcode(&jumpTo, 0, Registers.ra),
	];

	printf("fib(25), computed on a forked Mizu thread:\n");

	RegistersAndStack environment;
	setupEnvironment(environment, program[]);
	startFromEnvironment(program[], environment);

	return 0;
}
