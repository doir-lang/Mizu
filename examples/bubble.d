/**
* The D port of the C++ `tests/bubble.cpp`: bubble sort 100 numbers that have
* been copied onto Mizu's stack, then assert the result matches the expected
* ordering.
*
* Run with: `dub run -c example-bubble --compiler=ldc2`
*/
module examples.bubble;

import core.stdc.stdio : printf;

import mizu;

immutable ulong[100] numbers = [
	179, 1630, 754, 259, 858, 970, 310, 1612, 1269, 1000, 397, 783, 814, 1812, 1778, 641, 1925, 382, 82, 1147,
	152, 399, 1061, 1364, 1323, 1753, 96, 980, 1849, 1155, 1355, 1558, 168, 982, 1659, 598, 8, 1547, 52, 1164,
	1555, 445, 1069, 1921, 627, 1337, 845, 193, 1829, 1572, 1681, 1885, 197, 894, 1940, 1081, 1839, 313, 26, 116,
	692, 1105, 489, 1293, 502, 1019, 567, 496, 787, 1757, 1333, 1863, 1291, 1975, 744, 457, 1113, 1974, 246, 164,
	1441, 854, 1710, 583, 648, 484, 1279, 1890, 1588, 1073, 1944, 1231, 656, 566, 1676, 301, 1931, 667, 1167, 707
];

immutable ulong[100] sorted = [
	8, 26, 52, 82, 96, 116, 152, 164, 168, 179, 193, 197, 246, 259, 301, 310, 313, 382, 397, 399, 445, 457, 484, 489,
	496, 502, 566, 567, 583, 598, 627, 641, 648, 656, 667, 692, 707, 744, 754, 783, 787, 814, 845, 854, 858, 894, 970,
	980, 982, 1000, 1019, 1061, 1069, 1073, 1081, 1105, 1113, 1147, 1155, 1164, 1167, 1231, 1269, 1279, 1291, 1293,
	1323, 1333, 1337, 1355, 1364, 1441, 1547, 1555, 1558, 1572, 1588, 1612, 1630, 1659, 1676, 1681, 1710, 1753, 1757,
	1778, 1812, 1829, 1839, 1849, 1863, 1885, 1890, 1921, 1925, 1931, 1940, 1944, 1974, 1975
];

extern(C) int main() {
	// The array's address is only known at run time, so unlike the other
	// examples this program cannot be a compile-time constant.
	Opcode[36] program = [
		Opcode(&findLabel, 200).setImmediate(label2immediate("bub")),   // outer loop
		Opcode(&findLabel, 201).setImmediate(label2immediate("innr")),  // inner loop
		Opcode(&findLabel, 202).setImmediate(label2immediate("done")),  // finished
		Opcode(&loadImmediate, 204).setImmediate(ulong.sizeof),         // element size
		Opcode(&loadImmediate, 206).setImmediate(1),                    // the constant 1
		// a0 (size) = numbers.length, 205 = size - 1
		Opcode(&loadImmediate, Registers.a(0)).setImmediate(numbers.length),
		Opcode(&subtract, 205, Registers.a(0), 206),
		// Reserve size * 8 bytes of stack and copy the array into it.
		Opcode(&multiply, Registers.t(0), 204, Registers.a(0)),
		Opcode(&stackPush, 0, Registers.t(0)),
		Opcode(&pointerToStack, Registers.t(1)),
		Opcode(&loadImmediate, Registers.t(2)).setHostPointerLowerImmediate(numbers.ptr),
		Opcode(&loadUpperImmediate, Registers.t(2)).setHostPointerUpperImmediate(numbers.ptr),
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

	RegistersAndStack environment;
	setupEnvironment(environment, program[]);
	startFromEnvironment(program[], environment);

	// The sorted array is still sitting on Mizu's stack.
	auto result = cast(const(ulong)*)(environment.stackBottom - numbers.length * ulong.sizeof);
	foreach (i; 0 .. numbers.length)
		if (result[i] != sorted[i]) {
			printf("Mismatch at index %d: expected %llu, got %llu\n",
				cast(int) i, sorted[i], result[i]);
			return 1;
		}

	printf("Sorted %d numbers correctly.\n", cast(int) numbers.length);
	return 0;
}
