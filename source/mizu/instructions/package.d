/**
* Pulls in every instruction module, the way `mizu/instructions.hpp` used to
* include every instruction header.
*
* The FFI instructions are deliberately $(I not) here: they are an optional
* extra with a libffi dependency, so `import mizu.ffi;` separately.
*/
module mizu.instructions;

public import mizu.instructions.core;
public import mizu.instructions.dbg;
public import mizu.instructions.f32;
public import mizu.instructions.f64;
public import mizu.instructions.unsafe;
public import mizu.instructions.parallel;
