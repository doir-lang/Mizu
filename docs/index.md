# Welcome to Mizu's Documentorial!

This page is designed less like a direct reference and more like a tutorial. For a reference,
the source is documented with ddoc comments throughout — start at
[source/mizu/opcode.d](../source/mizu/opcode.d) and
[source/mizu/instructions/](../source/mizu/instructions/).

> The C++ version of this page used Sphinx and Breathe to splice Doxygen's output into the prose.
> That machinery was specific to the C++ headers and went away with them, so this is now plain
> Markdown that links into the D source instead.

## Programs

Programs in Mizu are represented by an array of `Opcode`s, each pairing an instruction with up to
three registers for it to act upon:

```d
struct Opcode {
    Instruction op;  // the instruction to perform
    Reg out_;        // register the result goes in ("out" is a D keyword)
    Reg a;           // first argument
    Reg b;           // second argument
}
```

An `Instruction` is just a function pointer, and `extern(C)` is load-bearing rather than
cosmetic — each instruction tail-calls the next one through this type, and a tail call is only
possible between functions that agree on their calling convention:

```d
alias Instruction = extern(C) void* function(Opcode* pc, ulong* registers,
    RegistersAndStack* env, ubyte* sp) @nogc nothrow;
```

A simple program that loads a number and prints it out looks like:

```d
import mizu;

// `static immutable` so the whole program lives in read-only data.
static immutable Opcode[3] program = [
    Opcode(&loadImmediate, Registers.t(0)).setImmediate(40),
    Opcode(&debugPrint, 0, Registers.t(0)),
    Opcode(&halt), // Execution has to be ended explicitly
];
```

That `static immutable` works because the immediate setters are ordinary integer arithmetic, so
the compiler can fold them. A program that embeds a **host pointer** cannot be folded — an
address is not a compile-time value — so those have to be built at run time; see
[examples/bubble.d](../examples/bubble.d).

## Registers

The code above looks up `t0` (the first temporary) through Mizu's register utilities. The layout
follows RISC-V:

| Register | Name | Purpose |
| --- | --- | --- |
| `x0` | `zero` | always zero |
| `x1`-`x20` | `t0`-`t19` | temporaries, saved by the caller if needed |
| `x21` | `ra` | return address (callee saved) |
| `x22`-`x256` | `a0`-`a234` | argument registers (callee saved) |

`a0`/`x22` and `a1`/`x23` are the canonical return registers.

```d
Registers.x(7)   // generic lookup
Registers.t(0)   // == 1
Registers.a(0)   // == 22
Registers.zero   // == 0
Registers.ra     // == 21
```

The C++ version spelled this `registers::t(0)`. In D, the namespace is capitalised as
`Registers`, because every instruction has a parameter named `registers` that would shadow it.
`registers` still exists as an alias for parity, and works fine outside an instruction body.

> **All Mizu registers are unsigned 64 bit integers regardless of host machine.** A "float
> register" is simply a register whose bits are being read as an `f32` or `f64`.

Those registers have to live in memory, so before Mizu can run a program it needs somewhere to
put them (and the stack). This memory is copied for each thread of execution.

```d
struct RegistersAndStack {
    Array!(ulong, memorySize) memory;  // registers and stack, 8kB by default
    ubyte* stackBoundary;              // where the registers end and the stack begins
    ubyte* stackBottom;                // the last byte of memory
    const(Opcode)* programStart;       // optional, used by findLabel
    const(Opcode)* programEnd;         // optional, used by findLabel
}
```

The stack pointer counts *down* from `stackBottom` towards `stackBoundary`. `setupEnvironment`
wires all of that up, and `startFromEnvironment` runs the program:

```d
extern(C) int main() {
    RegistersAndStack environment;
    setupEnvironment(environment, program[]); // Configures the pointers within the environment

    startFromEnvironment(program[], environment);
    return 0;
}
```

Passing the program to `setupEnvironment` is what lets `findLabel` know where to stop searching.
Leave it out and the search falls back to `maximumLabelSearch` instructions in either direction.

`MIZU_START_FROM_ENVIRONMENT` was a macro in C++ because it had to expand at the call site;
`startFromEnvironment` is an ordinary function here.

## Writing new instructions

New instructions (almost) always follow this template:

```d
extern(C) void* myInstruction(Opcode* pc, ulong* registers,
    RegistersAndStack* env, ubyte* sp) @nogc nothrow
{
    // Instruction code goes here
    mixin(mizuNext);
}
```

`pc` points at the current opcode and provides its `out_`, `a` and `b` fields, which index into
`registers`. `env` holds the memory and the stack bounds; `sp` is the current top of the stack.
Your code goes before `mixin(mizuNext)`, which hands control to the next instruction.

`mizuNext` has to stay a mixin rather than becoming a function, for the same reason `MIZU_NEXT()`
was a macro: the dispatch must be a tail call made by the instruction itself. See
[Tail calls](../README.md#tail-calls) in the README — this is the part of Mizu with real build
requirements attached.

There is no `MIZU_REGISTER_INSTRUCTION` to call. The C++ version needed it to populate the
serialization lookup tables at startup; `mizu.lookup` finds instructions at compile time with
`__traits(allMembers)` instead. If you want your own instructions to be serializable, add your
module to `instructionModules` in [source/mizu/lookup.d](../source/mizu/lookup.d).

## The instruction set

Instruction parameters are described in terms of the opcode fields:

- `out_`, `a` and `b` are the corresponding members of an `Opcode`.
- `b` sometimes takes an explicitly signed value, set with `.setBranchImmediate()`.
- `immediate` is a 32 bit value occupying both `a` and `b`, set with `.setImmediate()`.
- `signed immediate` is the same space, set with `.setImmediateSigned()`.
- `float immediate` is the same space again, set with `.setImmediateF32()`.

| Module | Contents |
| --- | --- |
| [core](../source/mizu/instructions/core.d) | labels and jumps, register/stack moves, comparisons, integer arithmetic |
| [dbg](../source/mizu/instructions/dbg.d) | `breakpoint` (named `dbg` because `debug` is a D keyword) |
| [f32](../source/mizu/instructions/f32.d) | 32 bit float arithmetic, comparisons and predicates |
| [f64](../source/mizu/instructions/f64.d) | the same for 64 bit, plus conversions between the two widths |
| [unsafe](../source/mizu/instructions/unsafe.d) | host heap allocation, raw pointers into the VM, `memcpy`/`memset` |
| [parallel](../source/mizu/instructions/parallel.d) | threads, channels and read/write mutexes |

`import mizu;` brings in all of them.

### Jump and branch offsets

Offsets are worth stating plainly, because off-by-ones here are easy and silent. An offset of `1`
means "the next instruction, as usual", `0` re-executes the jump itself, and negative offsets go
backwards — so an offset of `N` lands on `pc + N`. A loop whose body starts two instructions
above the branch therefore needs `setBranchImmediate(-2)`.

### FFI instructions

The FFI is deliberately not part of `mizu.instructions`, so that a program which never calls out
to the host does not drag in libffi:

```d
import mizu.ffi;
```

Mizu calls a foreign function the same way it calls one of its own — substitute `call` for
`jumpTo`. Describing a signature is a two-step dance: push the return type and then each
argument type onto a per-thread type stack, then turn that stack into a reusable interface.

```d
Opcode[/* ... */] program = [
    // Describe u64 strlen(void*)
    Opcode(&pushTypeU64),
    Opcode(&pushTypePointer),
    Opcode(&createInterface, 201),
    // 202 = &strlen, looked up in everything already loaded (library register 0)
    Opcode(&loadImmediate, 203).setHostPointerLowerImmediate(symbolName.ptr),
    Opcode(&loadUpperImmediate, 203).setHostPointerUpperImmediate(symbolName.ptr),
    Opcode(&loadLibraryFunction, 202, 0, 203),
    // a0 = the string, then t0 = strlen(a0)
    Opcode(&loadImmediate, Registers.a(0)).setHostPointerLowerImmediate(subject.ptr),
    Opcode(&loadUpperImmediate, Registers.a(0)).setHostPointerUpperImmediate(subject.ptr),
    Opcode(&callWithReturn, Registers.t(0), 202, 201),
    Opcode(&freeInterface, 0, 201, 0),
    Opcode(&halt),
];
```

Arguments are read from the argument registers (`a0`, `a1`, ...). The return type is mandatory —
use `pushTypeVoid` for a function that returns nothing, and `call` rather than `callWithReturn`.

[examples/threads.d](../examples/threads.d) shows a forked Mizu thread calling a host function
this way. Loading symbols out of the host executable needs `--export-dynamic` on POSIX, which
that example's configuration passes.

## Serialization

Once a program has been created it may be useful to save it to a file. Different builds put the
instruction functions at different addresses, so serializing replaces each address with an index
into a lookup table:

```d
Id lookupId(scope const(char)[] name);   // by name
Id lookupId(Instruction ptr);            // by function pointer
Instruction lookupPointer(Id id);
string lookupName(Id id);
```

Unlike the C++ version, these tables are built at compile time and live in read-only data, so
nothing allocates and nothing runs before `main`. IDs are an instruction's index in that table,
which makes them stable for a given build rather than dependent on static initialization order.
They still describe *one build configuration* though: adding, removing or reordering instructions
renumbers everything after the change. FFI instructions are placed last so that turning the FFI
on or off leaves the core IDs untouched.

[mizu.serialize](../source/mizu/serialize.d) does the pointer substitution for you:

```d
ubyte* toBinary(const(Opcode)[] program);
Opcode* fromBinary(const(void)[] binary);
```

Both return libfp dynarrays — free them with `fp.dynarray.free`.

[mizu.portable_format](../source/mizu/portable_format.d) goes one step further, packing some data
into the bottom of the program's stack and combining the whole thing into a format a standalone
runner can execute:

```d
ubyte* toPortable(const(Opcode)[] program, const(void)[] data = null);
ubyte* toPortable(const(Opcode)[] program, ref RegistersAndStack env);
PortableProgram fromPortable(const(void)[] binary);
```

The layout is: the serialized program, an all-zero opcode as a terminator, then the stack bytes.
`fromPortable` returns the program and an environment with that data already in place — call
`setupEnvironment` on it before running.

There is also `generateSourceFile`, which emits a self-contained D source file that runs a given
program in a given environment. The C++ equivalent generated a C++ header.

> Neither format accounts for differing endianness. Integers are stored little-endian and swapped
> on a big-endian host, and the op field is pinned at 64 bits, so a blob written on a 64 bit host
> does load on a 32 bit one — but a program is only portable between builds with the same
> instruction set.
