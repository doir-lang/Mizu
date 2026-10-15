/**
* The optional foreign function interface.
*
* Kept out of `mizu.instructions` so that a program that does not call out to the host does not drag in libffi: `import mizu.ffi;` explicitly.
*/
module mizu.ffi;

static import mizu.config;

public import mizu.ffi.loader;
public import mizu.ffi.instructions;
static if (!mizu.config.noLibFFI) public import mizu.ffi.libffi;
