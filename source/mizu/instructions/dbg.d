/**
* Debugging instructions.
*
* Named `dbg` rather than `debug` because `debug` is a D keyword.
*/
module mizu.instructions.dbg;

import mizu.opcode;

@nogc nothrow extern(C):

/**
* Stops in an attached debugger, by executing `int 3` on x86, and otherwise does nothing.
*
* Note: without a debugger the trap still happens, so on x86 POSIX it raises `SIGTRAP`, which ends the process unless handled.
*
* Examples:
* ---
* version(Posix) {
* 	import core.sys.posix.signal : sigaction, sigaction_t, sigemptyset, SIGTRAP;
* 	static extern(C) void resume(int) @nogc nothrow {}
* 	sigaction_t action, previous;
* 	assert(sigemptyset(&action.sa_mask) == 0);
* 	action.sa_handler = &resume;
* 	assert(sigaction(SIGTRAP, &action, &previous) == 0);
*
* 	static immutable Opcode[3] program = [
* 		Opcode(&breakpoint),
* 		Opcode(&loadImmediate, Registers.t(0)).setImmediate(1),
* 		Opcode(&halt),
* 	];
* 	RegistersAndStack env;
* 	setupEnvironment(env, program[]);
* 	cast(void) startFromEnvironment(program[], env);
* 	assert(sigaction(SIGTRAP, &previous, null) == 0);
* 	assert(env.memory[Registers.t(0)] == 1);
* }
* ---
*/
void* breakpoint(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	version(D_InlineAsm_X86_64) asm @nogc nothrow { int 3; }
	else version(D_InlineAsm_X86) asm @nogc nothrow { int 3; }
	mixin(mizuNext);
}
