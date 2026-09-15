/**
* Debugging instructions.
*
* Named `dbg` rather than `debug` because `debug` is a D keyword.
*/
module mizu.instructions.dbg;

import mizu.opcode;

@nogc nothrow extern(C):

/// Noop which can be used to add breakpoints into a program.
void* breakpoint(Opcode* pc, ulong* registers, RegistersAndStack* env, ubyte* sp) {
	version(D_InlineAsm_X86_64) asm @nogc nothrow { int 3; }
	else version(D_InlineAsm_X86) asm @nogc nothrow { int 3; }
	mixin(mizuNext);
}
