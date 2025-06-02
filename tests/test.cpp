#define MIZU_IMPLEMENTATION
#include <mizu/instructions.hpp>
#include <ffi/instructions.hpp>
#include <instructions/simd.hpp>

#include <GLFW/glfw3.h>

const char* windowTitle = "Rotating Cubes (Mizu)";
const char* enable = "glEnable";
const char* create_shader = "glCreateShader";
const char* shader_source = "glShaderSource";
const char* compile_shader = "glCompileShader";
const char* create_program = "glCreateProgram";
const char* attach_shader = "glAttachShader";
const char* link_program = "glLinkProgram";
const char* delete_shader = "glDeleteShader";
const char* gen_vertex_arrays = "glGenVertexArrays";
const char* gen_buffers = "glGenBuffers";
const char* bind_vertex_array = "glBindVertexArray";
const char* bind_buffer = "glBindBuffer";
const char* buffer_data = "glBufferData";
const char* vertex_attrib_pointer = "glVertexAttribPointer";
const char* enable_vertex_attrib_array = "glEnableVertexAttribArray";
const char* clear_color = "glClearColor";
const char* clear = "glClear";
const char* use_program = "glUseProgram";
const char* get_uniform_location = "glGetUniformLocation";
const char* uniform_matrix4fv = "glUniformMatrix4fv";
const char* draw_arrays = "glDrawArrays";

const char* view = "view";
const char* projection = "projection";
const char* model = "model";

const char* vertexShaderSource = "#version 330 core\n"
	"layout (location = 0) in vec3 aPos;\n"
	"layout (location = 1) in vec3 aColor;\n"
	"out vec3 vertexColor;\n"
	"uniform mat4 model;\n"
	"uniform mat4 view;\n"
	"uniform mat4 projection;\n"
	"void main() {\n"
	" vertexColor = aColor;\n"
	" gl_Position = projection * view * model * vec4(aPos, 1.0);\n"
	"}";

const char* fragmentShaderSource = "#version 330 core\n"
	"in vec3 vertexColor;\n"
	"out vec4 FragColor;\n"
	"void main() {\n"
	" FragColor = vec4(vertexColor, 1.0);\n"
	"}";

float cubeVertices[] = {
	// positions // colors
	// Front face (red)
	-0.5f, -0.5f, 0.5f, 1, 0, 0,
	0.5f, -0.5f, 0.5f, 1, 0, 0,
	0.5f, 0.5f, 0.5f, 1, 0, 0,
	0.5f, 0.5f, 0.5f, 1, 0, 0,
	-0.5f, 0.5f, 0.5f, 1, 0, 0,
	-0.5f, -0.5f, 0.5f, 1, 0, 0,

	// Back face (green)
	-0.5f, -0.5f, -0.5f, 0, 1, 0,
	0.5f, -0.5f, -0.5f, 0, 1, 0,
	0.5f, 0.5f, -0.5f, 0, 1, 0,
	0.5f, 0.5f, -0.5f, 0, 1, 0,
	-0.5f, 0.5f, -0.5f, 0, 1, 0,
	-0.5f, -0.5f, -0.5f, 0, 1, 0,

	// Left face (blue)
	-0.5f, 0.5f, 0.5f, 0, 0, 1,
	-0.5f, 0.5f, -0.5f, 0, 0, 1,
	-0.5f, -0.5f, -0.5f, 0, 0, 1,
	-0.5f, -0.5f, -0.5f, 0, 0, 1,
	-0.5f, -0.5f, 0.5f, 0, 0, 1,
	-0.5f, 0.5f, 0.5f, 0, 0, 1,

	// Right face (yellow)
	0.5f, 0.5f, 0.5f, 1, 1, 0,
	0.5f, 0.5f, -0.5f, 1, 1, 0,
	0.5f, -0.5f, -0.5f, 1, 1, 0,
	0.5f, -0.5f, -0.5f, 1, 1, 0,
	0.5f, -0.5f, 0.5f, 1, 1, 0,
	0.5f, 0.5f, 0.5f, 1, 1, 0,

	// Bottom face (cyan)
	-0.5f, -0.5f, -0.5f, 0, 1, 1,
	0.5f, -0.5f, -0.5f, 0, 1, 1,
	0.5f, -0.5f, 0.5f, 0, 1, 1,
	0.5f, -0.5f, 0.5f, 0, 1, 1,
	-0.5f, -0.5f, 0.5f, 0, 1, 1,
	-0.5f, -0.5f, -0.5f, 0, 1, 1,

	// Top face (magenta)
	-0.5f, 0.5f, -0.5f, 1, 0, 1,
	0.5f, 0.5f, -0.5f, 1, 0, 1,
	0.5f, 0.5f, 0.5f, 1, 0, 1,
	0.5f, 0.5f, 0.5f, 1, 0, 1,
	-0.5f, 0.5f, 0.5f, 1, 0, 1,
	-0.5f, 0.5f, -0.5f, 1, 0, 1
};

float positions[4][3] = {
	{-2.0f, 0.0f, -5.0f},
	{ 2.0f, 0.0f, -5.0f},
	{ 0.0f, 2.0f, -5.0f},
	{ 0.0f, -2.0f, -5.0f}
};

int main() {
	using namespace mizu;

	const static opcode program[] = {
		opcode{find_label, 200}.set_immediate(label2immediate("ident")),
		opcode{find_label, 201}.set_immediate(label2immediate("trans")),
		opcode{find_label, 202}.set_immediate(label2immediate("rotate")),
		opcode{load_immediate, 203}.set_immediate_f32(3.14159265358979323846),
		opcode{ffi::push_type_f32},
		opcode{ffi::push_type_f32},
		opcode{ffi::create_interface, 204},
		opcode{find_label, 205}.set_immediate(label2immediate("multiply")),
		opcode{find_label, 206}.set_immediate(label2immediate("mloop")),
		opcode{find_label, 207}.set_immediate(label2immediate("perspective")),


		// - 100 = sizeof(float)
		opcode{load_immediate, 100}.set_immediate(sizeof(float)),
		// - 101 = (16 + f32v.size()) * sizeof(float)
		opcode{simd_size_f32, t(0)},
		opcode{load_immediate, t(2)}.set_immediate(16),
		opcode{add, t(0), t(0), t(2)},
		opcode{multiply, 101, t(0), 100},
		// - 102 = 16 * sizeof(float)
		opcode{load_immediate, 102}.set_immediate(16 * sizeof(float)),
		// - 103 = &t0
		opcode{unsafe::pointer_to_register, 103, t(0)},
		// positions(104) = host pointer
		opcode{load_immediate, 104}.set_host_pointer_lower_immediate(positions),
		opcode{load_upper_immediate, 104}.set_host_pointer_upper_immediate(positions),

		// Main!
		opcode{find_label, t(0)}.set_immediate(label2immediate("main")),
		opcode{jump_to, 0, t(0)},

		// mat4_identity (a0 == mat)
		// 	uses t0, t1, t2
		opcode{label}.set_immediate(label2immediate("ident")),
			// - push 16 floats onto stack
			opcode{stack_push_immediate}.set_immediate_signed(16 * sizeof(float)),
			// - memset(stack, 0, 16 * sizeof(float))
			opcode{unsafe::pointer_to_stack, t(0)},
			opcode{load_immediate, t(1)}.set_immediate_f32(0),
			opcode{unsafe::set_memory_immediate, t(0), t(1)}.set_branch_immediate(16 * sizeof(float)),
			// - stack[0] = 1
			opcode{load_immediate, t(1)}.set_immediate_f32(1),
			opcode{load_immediate, t(2)}.set_immediate(0),
			opcode{stack_store_u32, 0, t(1), t(2)},
			// - stack[5] = 1
			opcode{load_immediate, t(2)}.set_immediate(5 * sizeof(float)),
			opcode{stack_store_u32, 0, t(1), t(2)},
			// - stack[10] = 1
			opcode{load_immediate, t(2)}.set_immediate(10 * sizeof(float)),
			opcode{stack_store_u32, 0, t(1), t(2)},
			// - stack[15] = 1
			opcode{load_immediate, t(2)}.set_immediate(15 * sizeof(float)),
			opcode{stack_store_u32, 0, t(1), t(2)},
			// - memcpy(a0, stack, 16 * sizeof(float))
			opcode{unsafe::copy_memory_immediate, a(0), t(0)}.set_branch_immediate(16 * sizeof(float)),
			// - pop 16 floats off stack
			opcode{stack_pop_immediate}.set_immediate_signed(16 * sizeof(float)),
			// - Return
			opcode{jump_to, 0, return_address},

		// mat4_translate (a0 == mat, f32s: a1 == x, a2 == y, a3 == z)
		//	uses t0, t1, t2, t3, t4
		opcode{label}.set_immediate(label2immediate("trans")),
			// - mat4_identity(a0)
			opcode{add, t(3), return_address},
			opcode{jump_to, return_address, 200}, // 200 = mat4_identity
			opcode{add, return_address, t(3)},
			// - mat[12] = a1
			opcode{load_immediate, t(0)}.set_immediate(12 * sizeof(float)),
			opcode{add, t(0), a(0), t(0)},
			opcode{unsafe::pointer_to_register, t(1), a(1)},
			opcode{unsafe::copy_memory_immediate, t(0), t(1)}.set_branch_immediate(sizeof(float)),
			// - mat[13] = a2
			opcode{load_immediate, t(0)}.set_immediate(13 * sizeof(float)),
			opcode{add, t(0), a(0), t(0)},
			opcode{unsafe::pointer_to_register, t(1), a(2)},
			opcode{unsafe::copy_memory_immediate, t(0), t(1)}.set_branch_immediate(sizeof(float)),
			// - mat[14] = a3
			opcode{load_immediate, t(0)}.set_immediate(14 * sizeof(float)),
			opcode{add, t(0), a(0), t(0)},
			opcode{unsafe::pointer_to_register, t(1), a(3)},
			opcode{unsafe::copy_memory_immediate, t(0), t(1)}.set_branch_immediate(sizeof(float)),
			// - Return
			opcode{jump_to, 0, return_address},

		// mat4_rotate (a0 == mat, f32s: a1 == angleDegrees, a2 == x, a3 == y, a4 == z)
		//	uses t0, t1, t2, t3, t4
		opcode{label}.set_immediate(label2immediate("rotate")),
			// - t0 = a1 * M_PI / 180.0f;
			opcode{multiply_f32, t(0), a(1), 203},
			opcode{load_immediate, t(1)}.set_immediate_f32(180),
			opcode{multiply_f32, t(0), t(0), t(1)},
			// - t2 = cos
			opcode{load_immediate, t(2)}.set_host_pointer_lower_immediate((void*)std::cosf),
			opcode{load_upper_immediate, t(2)}.set_host_pointer_upper_immediate((void*)std::cosf),
			// - t1(c) = cos(t0), t3 = a0 (temporarily)
			opcode{add, t(3), a(0)},
			opcode{add, a(0), t(0)},
			opcode{ffi::call_with_return, t(1), t(2), 204},
			// - t2 = sin
			opcode{load_immediate, t(2)}.set_host_pointer_lower_immediate((void*)std::sinf),
			opcode{load_upper_immediate, t(2)}.set_host_pointer_upper_immediate((void*)std::sinf),
			// - t2(s) = sin(t0), a0 = t3
			opcode{add, a(0), t(0)},
			opcode{ffi::call_with_return, t(2), t(2), 204},
			opcode{add, a(0), t(3)},
			// - t3(one_c) = 1 - t1
			opcode{load_immediate, t(3)}.set_immediate_f32(1),
			opcode{subtract_f32, t(3), t(3), t(1)},

			// Push 16 floats onto stack
			opcode{stack_push_immediate}.set_immediate_signed(16 * sizeof(float)),
			// - t0 = c(t1) + x(a2) * x(a2) * one_c(t3);
			opcode{multiply_f32, t(0), a(2), a(2)},
			opcode{multiply_f32, t(0), t(0), t(3)},
			opcode{add_f32, t(0), t(1), t(0)},
			// - stack[0] = t0, t4 = offset
			opcode{load_immediate, t(4)}.set_immediate_signed(0 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},
			// - t0 = x(a2) * y(a3) * one_c(t3) + t4; t4 = z(a4) * s(t2)
			opcode{multiply_f32, t(4), a(4), t(2)},
			opcode{multiply_f32, t(0), a(2), a(3)},
			opcode{multiply_f32, t(0), t(0), t(3)},
			opcode{add_f32, t(0), t(0), t(4)},
			// - stack[1] = t0, t4 = offset
			opcode{load_immediate, t(4)}.set_immediate_signed(1 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},
			// - t0 = x(a2) * z(a4) * one_c(t3) - t4; t4 = y(a3) * s(t2)
			opcode{multiply_f32, t(4), a(3), t(2)},
			opcode{multiply_f32, t(0), a(2), a(4)},
			opcode{multiply_f32, t(0), t(0), t(3)},
			opcode{subtract_f32, t(0), t(0), t(4)},
			// - stack[2] = t0, t4 = offset
			opcode{load_immediate, t(4)}.set_immediate_signed(2 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},
			// - stack[3] = 0
			opcode{load_immediate, t(0)}.set_immediate_f32(0),
			opcode{load_immediate, t(4)}.set_immediate_signed(3 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[4] = y * x * one_c - z * s
			opcode{multiply_f32, t(4), a(4), t(2)}, // t4 = z * s
			opcode{multiply_f32, t(0), a(3), a(2)}, // t0 = y * x
			opcode{multiply_f32, t(0), t(0), t(3)}, // t0 *= one_c
			opcode{subtract_f32, t(0), t(0), t(4)}, // t0 -= t4
			opcode{load_immediate, t(4)}.set_immediate_signed(4 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[5] = c + y * y * one_c
			opcode{multiply_f32, t(0), a(3), a(3)}, // t0 = y * y
			opcode{multiply_f32, t(0), t(0), t(3)}, // t0 *= one_c
			opcode{add_f32, t(0), t(1), t(0)}, // t0 = c + ...
			opcode{load_immediate, t(4)}.set_immediate_signed(5 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[6] = y * z * one_c + x * s
			opcode{multiply_f32, t(4), a(2), t(2)}, // t4 = x * s
			opcode{multiply_f32, t(0), a(3), a(4)}, // t0 = y * z
			opcode{multiply_f32, t(0), t(0), t(3)}, // t0 *= one_c
			opcode{add_f32, t(0), t(0), t(4)}, // t0 += t4
			opcode{load_immediate, t(4)}.set_immediate_signed(6 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[7] = 0.0f
			opcode{load_immediate, t(0)}.set_immediate_f32(0),
			opcode{load_immediate, t(4)}.set_immediate_signed(7 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[8] = z * x * one_c + y * s
			opcode{multiply_f32, t(4), a(3), t(2)}, // t4 = y * s
			opcode{multiply_f32, t(0), a(4), a(2)}, // t0 = z * x
			opcode{multiply_f32, t(0), t(0), t(3)}, // t0 *= one_c
			opcode{add_f32, t(0), t(0), t(4)}, // t0 += t4
			opcode{load_immediate, t(4)}.set_immediate_signed(8 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[9] = z * y * one_c - x * s
			opcode{multiply_f32, t(4), a(2), t(2)}, // t4 = x * s
			opcode{multiply_f32, t(0), a(4), a(3)}, // t0 = z * y
			opcode{multiply_f32, t(0), t(0), t(3)}, // t0 *= one_c
			opcode{subtract_f32, t(0), t(0), t(4)}, // t0 -= t4
			opcode{load_immediate, t(4)}.set_immediate_signed(9 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[10] = c + z * z * one_c
			opcode{multiply_f32, t(0), a(4), a(4)}, // t0 = z * z
			opcode{multiply_f32, t(0), t(0), t(3)}, // t0 *= one_c
			opcode{add_f32, t(0), t(1), t(0)}, // t0 = c + ...
			opcode{load_immediate, t(4)}.set_immediate_signed(10 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[11] = 0.0f
			opcode{load_immediate, t(0)}.set_immediate_f32(0),
			opcode{load_immediate, t(4)}.set_immediate_signed(11 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[12], stack[13], stack[14] = 0.0f
			opcode{load_immediate, t(0)}.set_immediate_f32(0),
			opcode{load_immediate, t(4)}.set_immediate_signed(12 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},
			opcode{load_immediate, t(4)}.set_immediate_signed(13 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},
			opcode{load_immediate, t(4)}.set_immediate_signed(14 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// stack[15] = 1.0f
			opcode{load_immediate, t(0)}.set_immediate_f32(1.0f),
			opcode{load_immediate, t(4)}.set_immediate_signed(15 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(4)},

			// mat(a0) = stack
			opcode{unsafe::pointer_to_stack, t(0)},
			opcode{unsafe::copy_memory_immediate, a(0), t(0)}.set_branch_immediate(16 * sizeof(float)),
			// Pop 16 floats off stack
			opcode{stack_pop_immediate}.set_immediate_signed(16 * sizeof(float)),
			// return
			opcode{jump_to, 0, return_address},

		// mat4_perspective (a0 == mat, f32s: a1 == fovDegrees, a2 == aspectRatio, a3 == near_clip_distance, a4 == far_clip_distance)
		//	uses t0, t1, t2, t3, t4
		opcode{label}.set_immediate(label2immediate("perspective")),
			// - Push 16 floats onto the stack
			opcode{stack_push_immediate}.set_immediate_signed(16 * sizeof(float)),
			// - mat4_identity(stack)
			opcode{add, t(3), return_address},
			opcode{add, t(4), a(0)},
			opcode{unsafe::pointer_to_stack, a(0)},
			opcode{jump_to, return_address, 200}, // 200 = mat4_identity
			opcode{add, return_address, t(3)},
			opcode{add, a(0), t(4)},

			// float f = 1.0f / tanf(fovDeg * M_PI / 180.0f / 2.0f);
			// - t0(f) = fovDeg(a1) * M_PI / 180.0f / 2.0f;
			opcode{load_immediate, t(0)}.set_immediate_f32(180 * 2),
			opcode{divide_f32, t(0), 203, t(0)},
			opcode{multiply_f32, t(0), a(1), t(0)},
			// - t1 = tan
			opcode{load_immediate, t(1)}.set_host_pointer_lower_immediate((void*)std::tanf),
			opcode{load_upper_immediate, t(1)}.set_host_pointer_upper_immediate((void*)std::tanf),
			// - t0 = tan(t0), t2 = a0 (temporarily)
			opcode{add, t(2), a(0)},
			opcode{add, a(0), t(0)},
			opcode{ffi::call_with_return, t(0), t(1), 204},
			opcode{add, a(0), t(2)},
			// - t0 = 1 / t0
			opcode{load_immediate, t(1)}.set_immediate_f32(1),
			opcode{divide_f32, t(0), t(1), t(0)},

			// - t1 = f(t0) / aspect(a2)
			opcode{divide_f32, t(1), t(0), a(2)},
			// - stack[0] = t1, t2 = offset
			opcode{load_immediate, t(2)}.set_immediate(0 * sizeof(float)),
			opcode{stack_store_u32, 0, t(1), t(2)},
			// - stack[5] = f(t0), t2 = offset
			opcode{load_immediate, t(2)}.set_immediate(5 * sizeof(float)),
			opcode{stack_store_u32, 0, t(0), t(2)},
			// - t1 = (far(a4) + near(a3)) / (near(a3) - far(a4));
			opcode{add_f32, t(1), a(4), a(3)},
			opcode{subtract_f32, t(2), a(3), a(4)},
			opcode{divide_f32, t(1), t(1), t(2)},
			// - stack[10] = t1, t2 = offset
			opcode{load_immediate, t(2)}.set_immediate(10 * sizeof(float)),
			opcode{stack_store_u32, 0, t(1), t(2)},
			// - stack[11] = -1, t2 = offset
			opcode{load_immediate, t(1)}.set_immediate_f32(-1),
			opcode{load_immediate, t(2)}.set_immediate(11 * sizeof(float)),
			opcode{stack_store_u32, 0, t(1), t(2)},
			// - t1 = (2 * far(a4) * near(a3)) / (near(a3) - far(a4));
			opcode{multiply_f32, t(1), a(4), a(3)},
			opcode{load_immediate, t(2)}.set_immediate_f32(2),
			opcode{multiply_f32, t(1), t(1), t(2)},
			opcode{subtract_f32, t(2), a(3), a(4)},
			opcode{divide_f32, t(1), t(1), t(2)},
			// - stack[14] = t1, t2 = offset
			opcode{load_immediate, t(2)}.set_immediate(14 * sizeof(float)),
			opcode{stack_store_u32, 0, t(1), t(2)},
			// - stack[15] = 0, t2 = offset
			opcode{load_immediate, t(1)}.set_immediate_f32(0),
			opcode{load_immediate, t(2)}.set_immediate(15 * sizeof(float)),
			opcode{stack_store_u32, 0, t(1), t(2)},

			// mat(a0) = stack
			opcode{unsafe::pointer_to_stack, t(0)},
			opcode{unsafe::copy_memory_immediate, a(0), t(0)}.set_branch_immediate(16 * sizeof(float)),
			// Pop 16 floats off stack
			opcode{stack_pop_immediate}.set_immediate_signed(16 * sizeof(float)),
			// return
			opcode{jump_to, 0, return_address},

		// mat4_multiply (a0 == result, a1 == a, a2 == b)
		// 	uses t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, a3, a4, a5
		opcode{label}.set_immediate(label2immediate("multiply")),
			// - Push 16 + f32v.size() floats onto the stack
			opcode{stack_push, 0, 100},

			// - (t1) f32v b_col0(&b[0], std::experimental::element_aligned);
			opcode{load_immediate, t(5)}.set_immediate(0 * sizeof(float)),
			opcode{add, t(5), a(2), t(5)},
			opcode{simd_create_f32, t(1)},
			opcode{unsafe::simd_load_pointer_f32, t(1), t(5)},
			// - (t2) f32v b_col1(&b[4], std::experimental::element_aligned);
			opcode{load_immediate, t(5)}.set_immediate(4 * sizeof(float)),
			opcode{add, t(5), a(2), t(5)},
			opcode{simd_create_f32, t(2)},
			opcode{unsafe::simd_load_pointer_f32, t(2), t(5)},
			// - (t3) f32v b_col2(&b[8], std::experimental::element_aligned);
			opcode{load_immediate, t(5)}.set_immediate(8 * sizeof(float)),
			opcode{add, t(5), a(2), t(5)},
			opcode{simd_create_f32, t(3)},
			opcode{unsafe::simd_load_pointer_f32, t(3), t(5)},
			// - (t4) f32v b_col3(&b[12], std::experimental::element_aligned);
			opcode{load_immediate, t(5)}.set_immediate(12 * sizeof(float)),
			opcode{add, t(5), a(2), t(5)},
			opcode{simd_create_f32, t(4)},
			opcode{unsafe::simd_load_pointer_f32, t(4), t(5)},

			// Mark t5, t6, t7, t8 as simd
			opcode{simd_create_f32, t(5)},
			opcode{simd_create_f32, t(6)},
			opcode{simd_create_f32, t(7)},
			opcode{simd_create_f32, t(8)},

			// - a3(row) = 0; a4(size) = 4; t9(done) = ?
			opcode{add, a(3), zero},
			opcode{load_immediate, a(4)}.set_immediate(4),
			// for (int row = 0; row < 4; ++row)
			opcode{label}.set_immediate(label2immediate("mloop")),
				// - t9 = row * 4
				opcode{load_immediate, t(9)}.set_immediate(4),
				opcode{multiply, t(9), a(3), t(9)},
				// - (t5) simd_f32 a_row0(a[row * 4 + 0]); t0 == offset
				opcode{load_immediate, t(0)}.set_immediate(0),
				opcode{add, t(0), t(0), t(9)},
				opcode{multiply, t(0), t(0), 100},
				opcode{add, t(0), t(0), a(1)},
				opcode{unsafe::copy_memory, 103, t(0), 100}, // Copy the float into t(0)
				opcode{simd_broadcast_f32, t(5), t(0)},
				// - (t6) simd_f32 a_row1(a[row * 4 + 1]); t0 == offset
				opcode{load_immediate, t(0)}.set_immediate(1),
				opcode{add, t(0), t(0), t(9)},
				opcode{multiply, t(0), t(0), 100},
				opcode{add, t(0), t(0), a(1)},
				opcode{unsafe::copy_memory, 103, t(0), 100}, // Copy the float into t(0)
				opcode{simd_broadcast_f32, t(6), t(0)},
				// - (t7) simd_f32 a_row2(a[row * 4 + 2]); t0 == offset
				opcode{load_immediate, t(0)}.set_immediate(2),
				opcode{add, t(0), t(0), t(9)},
				opcode{multiply, t(0), t(0), 100},
				opcode{add, t(0), t(0), a(1)},
				opcode{unsafe::copy_memory, 103, t(0), 100}, // Copy the float into t(0)
				opcode{simd_broadcast_f32, t(7), t(0)},
				// - (t8) simd_f32 a_row3(a[row * 4 + 3]); t0 == offset
				opcode{load_immediate, t(0)}.set_immediate(3),
				opcode{add, t(0), t(0), t(9)},
				opcode{multiply, t(0), t(0), 100},
				opcode{add, t(0), t(0), a(1)},
				opcode{unsafe::copy_memory, 103, t(0), 100}, // Copy the float into t(0)
				opcode{simd_broadcast_f32, t(8), t(0)},

				// - We need to simd compute with the last temporaries for a while
				opcode{simd_create_f32, t(0)},
				opcode{simd_create_f32, t(9)},
				// t8 = a_row0(t5) * b_col0(t1) + a_row1(t6) * b_col1(t2)
				// 	+ a_row2(t7) * b_col2(t3) + a_row3(t8) * b_col3(t4);
				opcode{simd_multiply_f32, t(0), t(5), t(1)},
				opcode{simd_multiply_f32, t(9), t(6), t(2)},
				opcode{simd_add_f32, t(0), t(0), t(9)},
				opcode{simd_multiply_f32, t(9), t(7), t(3)},
				opcode{simd_add_f32, t(0), t(0), t(9)},
				opcode{simd_multiply_f32, t(9), t(8), t(4)},
				opcode{simd_add_f32, t(8), t(0), t(9)},
				// - Unmark t0, t9 as simd
				opcode{simd_free_f32, 0, t(0)},
				opcode{simd_free_f32, 0, t(9)},

				// - t9 = row * 4 * sizeof(float)
				opcode{load_immediate, t(9)}.set_immediate(4),
				opcode{multiply, t(9), a(3), t(9)},
				opcode{multiply, t(9), t(9), 100},
				// - t8.copy_to(sp + t9)
				opcode{simd_store_stack_f32, 0, t(8), t(9)},

				// if(row < 4) ++row; continue
				opcode{load_immediate, t(0)}.set_immediate(1),
				opcode{add, a(3), a(3), t(0)},
				opcode{set_if_less, t(9), a(3), a(4)},
				opcode{branch_to, 0, t(9), 205}, // 205 == mloop

			// Loop done!
			opcode{label}.set_immediate(label2immediate("mdone")),
			// Cleanup simd
			opcode{simd_free_f32, 0, t(1)},
			opcode{simd_free_f32, 0, t(2)},
			opcode{simd_free_f32, 0, t(3)},
			opcode{simd_free_f32, 0, t(4)},
			opcode{simd_free_f32, 0, t(5)},
			opcode{simd_free_f32, 0, t(6)},
			opcode{simd_free_f32, 0, t(7)},
			opcode{simd_free_f32, 0, t(8)},
			// memcpy(a0, stack, 16 * sizeof(float))
			opcode{unsafe::pointer_to_stack, t(0)},
			opcode{unsafe::copy_memory, a(0), t(0), 102}, // 102 == 16 * sizeof(float)
			// Pop floats off stack
			opcode{stack_pop, 0, 100},
			// return
			opcode{jump_to, 0, return_address},



		// Main
		opcode{label}.set_immediate(label2immediate("main")),
			// t0 = &glfwInit
			opcode{load_immediate, t(0)}.set_host_pointer_lower_immediate((void*)glfwInit),
			opcode{load_upper_immediate, t(0)}.set_host_pointer_upper_immediate((void*)glfwInit),
			// 225 = &glfwTerminate
			opcode{load_immediate, 225}.set_host_pointer_lower_immediate((void*)glfwTerminate),
			opcode{load_upper_immediate, 225}.set_host_pointer_upper_immediate((void*)glfwTerminate),
			// 125 = void(*)()
			opcode{ffi::push_type_void},
			opcode{ffi::create_interface, 125},
			// glfwInit()
			opcode{ffi::call, 0, t(0), 125},

			// t0 = &glfwWindowHint
			opcode{load_immediate, t(0)}.set_host_pointer_lower_immediate((void*)glfwWindowHint),
			opcode{load_upper_immediate, t(0)}.set_host_pointer_upper_immediate((void*)glfwWindowHint),
			// t1 = void(*)(int, int)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_i32},
			opcode{ffi::push_type_i32},
			opcode{ffi::create_interface, t(1)},
			// - glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
			opcode{load_immediate, a(0)}.set_immediate(GLFW_CONTEXT_VERSION_MAJOR),
			opcode{load_immediate, a(1)}.set_immediate(3),
			opcode{ffi::call, 0, t(0), t(1)},
			// - glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
			opcode{load_immediate, a(0)}.set_immediate(GLFW_CONTEXT_VERSION_MINOR),
			opcode{load_immediate, a(1)}.set_immediate(3),
			opcode{ffi::call, 0, t(0), t(1)},
			// - glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
			opcode{load_immediate, a(0)}.set_immediate(GLFW_OPENGL_PROFILE),
			opcode{load_immediate, a(1)}.set_immediate(GLFW_OPENGL_CORE_PROFILE),
			opcode{ffi::call, 0, t(0), t(1)},
			// - glfwWindowHint(GLFW_RESIZABLE, 0);
			opcode{load_immediate, a(0)}.set_immediate(GLFW_RESIZABLE),
			opcode{load_immediate, a(1)}.set_immediate(0),
			opcode{ffi::call, 0, t(0), t(1)},
			// cleanup
			opcode{ffi::free_interface, 0, t(1)},

			// t0 = &glfwCreateWindow
			opcode{load_immediate, t(0)}.set_host_pointer_lower_immediate((void*)glfwCreateWindow),
			opcode{load_upper_immediate, t(0)}.set_host_pointer_upper_immediate((void*)glfwCreateWindow),
			// t1 = void*(*)(int, int, void*, void*, void*)
			opcode{ffi::push_type_pointer},
			opcode{ffi::push_type_i32},
			opcode{ffi::push_type_i32},
			opcode{ffi::push_type_pointer},
			opcode{ffi::push_type_pointer},
			opcode{ffi::push_type_pointer},
			opcode{ffi::create_interface, t(1)},
			// t0(window) = glfwCreateWindow(800, 600, "Rotating Cubes (Mizu)", NULL, NULL)
			opcode{load_immediate, a(0)}.set_immediate(800),
			opcode{load_immediate, a(1)}.set_immediate(600),
			opcode{load_immediate, a(2)}.set_host_pointer_lower_immediate(windowTitle),
			opcode{load_upper_immediate, a(2)}.set_host_pointer_upper_immediate(windowTitle),
			opcode{add, a(3), zero},
			opcode{add, a(4), zero},
			opcode{ffi::call_with_return, t(0), t(0), t(1)},
			opcode{ffi::free_interface, 0, t(1)},

			// - if (!window(t0)) { glfwTerminate(); halt }
			opcode{set_if_not_equal, t(1), t(0), zero},
			opcode{branch_relative_immediate, 0, t(1)}.set_branch_immediate(3),
				// glfwTerminate
				opcode{ffi::call, 0, 225, 125},
				opcode{halt},

			// t1 = glfwMakeContextCurrent
			opcode{load_immediate, t(1)}.set_host_pointer_lower_immediate((void*)glfwMakeContextCurrent),
			opcode{load_upper_immediate, t(1)}.set_host_pointer_upper_immediate((void*)glfwMakeContextCurrent),
			// 128 = void(*)(void*)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_pointer},
			opcode{ffi::create_interface, 128},
			// glfwMakeContextCurrent(window(t0))
			opcode{add, a(0), t(0), zero},
			opcode{ffi::call, 0, t(1), 128},

			// 226 = glfwGetProcAddress
			opcode{load_immediate, 226}.set_host_pointer_lower_immediate((void*)glfwGetProcAddress),
			opcode{load_upper_immediate, 226}.set_host_pointer_upper_immediate((void*)glfwGetProcAddress),
			// 126 = void*(*)(void*)
			opcode{ffi::push_type_pointer},
			opcode{ffi::push_type_pointer},
			opcode{ffi::create_interface, 126},

			// t1 = glfwGetProcAddress("glEnable")
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(enable),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(enable),
			opcode{ffi::call_with_return, t(1), 226, 126},
			// 120 = void(*)(uint32_t)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_u32},
			opcode{ffi::create_interface, 120},
			// glEnable(GL_DEPTH_TEST)
			opcode{load_immediate, a(0)}.set_immediate(GL_DEPTH_TEST),
			opcode{ffi::call, 0, t(1), 120},


			// t1 = glfwGetProcAddress("glCreateShader")
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(create_shader),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(create_shader),
			opcode{ffi::call_with_return, t(1), 226, 126},
			// t2 = uint32_t(*)(uint32_t)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_u32},
			opcode{ffi::create_interface, t(2)},
			// t3 = glfwGetProcAddress("glShaderSource")
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(shader_source),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(shader_source),
			opcode{ffi::call_with_return, t(3), 226, 126},
			// t4 = void(*)(uint32_t, uint32_t, void*, void*)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_pointer},
			opcode{ffi::push_type_pointer},
			opcode{ffi::create_interface, t(4)},
			// t5 = glfwGetProcAddress("glCompileShader") // uses 120
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(compile_shader),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(compile_shader),
			opcode{ffi::call_with_return, t(5), 226, 126},

			// GLuint vertexShader(t6) = create_shader(GL_VERTEX_SHADER);
			opcode{load_immediate, a(0)}.set_immediate(GL_VERTEX_SHADER),
			opcode{ffi::call_with_return, t(6), t(1), t(2)},
			// shader_source(vertexShader(t6), 1, &vertexShaderSource, NULL);
			opcode{add, a(0), t(6)},
			opcode{load_immediate, a(1)}.set_immediate(1),
			opcode{load_immediate, a(2)}.set_host_pointer_lower_immediate(&vertexShaderSource),
			opcode{load_upper_immediate, a(2)}.set_host_pointer_upper_immediate(&vertexShaderSource),
			opcode{add, a(4), zero},
			opcode{ffi::call, 0, t(3), t(4)},
			// compile_shader(vertexShader(t6));
			opcode{ffi::call, 0, t(5), 120}, // 120 == void(*)(uint32_t)
			// GLuint fragmentShader(t7) = create_shader(GL_FRAGMENT_SHADER);
			opcode{load_immediate, a(0)}.set_immediate(GL_FRAGMENT_SHADER),
			opcode{ffi::call_with_return, t(7), t(1), t(2)},
			opcode{ffi::free_interface, 0, t(2)},
			// shader_source(fragmentShader(t7), 1, &fragmentShaderSource, NULL);
			opcode{add, a(0), t(7)},
			opcode{load_immediate, a(1)}.set_immediate(1),
			opcode{load_immediate, a(2)}.set_host_pointer_lower_immediate(&fragmentShaderSource),
			opcode{load_upper_immediate, a(2)}.set_host_pointer_upper_immediate(&fragmentShaderSource),
			opcode{add, a(4), zero},
			opcode{ffi::call, 0, t(3), t(4)},
			opcode{ffi::free_interface, 0, t(4)},
			// compile_shader(fragmentShader(t7));
			opcode{ffi::call, 0, t(5), 120}, // 120 == void(*)(uint32_t)

			// t2 = glfwGetProcAddress("glCreateProgram")
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(create_program),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(create_program),
			opcode{ffi::call_with_return, t(2), 226, 126},
			// t3 = uint32_t(*)()
			opcode{ffi::push_type_u32},
			opcode{ffi::create_interface, t(3)},
			// shaderProgram(t1) = glCreateProgram();
			opcode{ffi::call_with_return, t(1), t(2), t(3)},
			opcode{ffi::free_interface, 0, t(3)},

			// t2 = glfwGetProcAddress("glAttachShader")
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(attach_shader),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(attach_shader),
			opcode{ffi::call_with_return, t(2), 226, 126},
			// t3 = void(*)(uint32_t, uint32_t)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_u32},
			opcode{ffi::create_interface, t(3)},
			// glAttachShader(shaderProgram(t1), vertexShader(t6));
			opcode{add, a(0), t(1)},
			opcode{add, a(1), t(6)},
			opcode{ffi::call, 0, t(2), t(3)},
			// glAttachShader(shaderProgram(t1), fragmentShader(t7));
			opcode{add, a(1), t(7)},
			opcode{ffi::call, 0, t(2), t(3)},
			opcode{ffi::free_interface, 0, t(3)},

			// t2 = glfwGetProcAddress("glLinkProgram")
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(link_program),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(link_program),
			opcode{ffi::call_with_return, t(2), 226, 126},
			// link_program(shaderProgram(t1));
			opcode{add, a(0), t(1)},
			opcode{ffi::call, 0, t(2), 120}, // 120 == void(*)(uint32_t)

			// t2 = glfwGetProcAddress("glDeleteShader")
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(delete_shader),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(delete_shader),
			opcode{ffi::call_with_return, t(2), 226, 126},
			// delete_shader(vertexShader(t6));
			opcode{add, a(0), t(6)},
			opcode{ffi::call, 0, t(2), 120}, // 120 == void(*)(uint32_t)
			// delete_shader(fragmentShader(t7));
			opcode{add, a(0), t(7)},
			opcode{ffi::call, 0, t(2), 120}, // 120 = void(*)(uint32_t)

			// t4 = glGenVertexArrays
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(gen_vertex_arrays),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(gen_vertex_arrays),
			opcode{ffi::call_with_return, t(4), 226, 126},
			// t5 = void(*)(uint32_t, void*)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_pointer},
			opcode{ffi::create_interface, t(5)},
			// glGenVertexArrays(1, &VAO(t2))
			opcode{load_immediate, a(0)}.set_immediate(1),
			opcode{unsafe::pointer_to_register, a(1), t(2)},
			opcode{ffi::call, 0, t(4), t(5)},
			// t4 = glGenBuffers
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(gen_buffers),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(gen_buffers),
			opcode{ffi::call_with_return, t(4), 226, 126},
			// gen_vertex_buffers(1, &VBO(t3))
			opcode{load_immediate, a(0)}.set_immediate(1),
			opcode{unsafe::pointer_to_register, a(1), t(3)},
			opcode{ffi::call, 0, t(4), t(5)},
			opcode{ffi::free_interface, 0, t(5)},

			// t4 = glBindVertexArray
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(bind_vertex_array),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(bind_vertex_array),
			opcode{ffi::call_with_return, t(4), 226, 126},
			// glBindVertexArray(VAO(t2))
			opcode{add, a(0), t(2)},
			opcode{ffi::call, 0, t(4), 120}, // 120 == void(*)(uint32_t)

			// t4 = glBindBuffer
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(bind_buffer),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(bind_buffer),
			opcode{ffi::call_with_return, t(4), 226, 126},
			// t5 = void(*)(uint32_t, uint32_t)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_u32},
			opcode{ffi::create_interface, t(5)},
			// glBindBuffer(GL_ARRAY_BUFFER, VBO(t3));
			opcode{load_immediate, a(0)}.set_immediate(GL_ARRAY_BUFFER),
			opcode{add, a(1), t(3)},
			opcode{ffi::call, 0, t(4), t(5)},
			opcode{ffi::free_interface, 0, t(5)},

			// t4 = glBufferData
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(buffer_data),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(buffer_data),
			opcode{ffi::call_with_return, t(4), 226, 126},
			// t5 = void(*)(uint32_t, size_t, void*, uint32_t)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_u64},
			opcode{ffi::push_type_pointer},
			opcode{ffi::push_type_u32},
			opcode{ffi::create_interface, t(5)},
			// glBufferData(GL_ARRAY_BUFFER, sizeof(cubeVertices), cubeVertices, GL_STATIC_DRAW);
			opcode{load_immediate, a(0)}.set_immediate(GL_ARRAY_BUFFER),
			opcode{load_immediate, a(1)}.set_immediate(sizeof(cubeVertices)),
			opcode{load_immediate, a(2)}.set_host_pointer_lower_immediate(cubeVertices),
			opcode{load_upper_immediate, a(2)}.set_host_pointer_upper_immediate(cubeVertices),
			opcode{load_immediate, a(3)}.set_immediate(GL_STATIC_DRAW),
			opcode{ffi::call, 0, t(4), t(5)},
			opcode{ffi::free_interface, 0, t(5)},

			// t4 = glVertexAttribPointer
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(vertex_attrib_pointer),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(vertex_attrib_pointer),
			opcode{ffi::call_with_return, t(4), 226, 126},
			// t5 = void(*)(uint32_t, int32_t, uint32_t, uint32_t, uint32_t, void*)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_i32},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_pointer},
			opcode{ffi::create_interface, t(5)},
			// t6 = glEnableVertexAttribArray; uses 120 == void(*)(uint32_t)
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(enable_vertex_attrib_array),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(enable_vertex_attrib_array),
			opcode{ffi::call_with_return, t(6), 226, 126},
			// glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), NULL);
			opcode{add, a(0), zero},
			opcode{load_immediate, a(1)}.set_immediate(3),
			opcode{load_immediate, a(2)}.set_immediate(GL_FLOAT),
			opcode{load_immediate, a(3)}.set_immediate(GL_FALSE),
			opcode{load_immediate, a(4)}.set_immediate(6 * sizeof(float)),
			opcode{add, a(5), zero},
			opcode{ffi::call, 0, t(4), t(5)},
			// glEnableVertexAttribArray(0);
			opcode{ffi::call, 0, t(6), 120}, // 120 == void(*)(uint32_t)
			// glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 6 * sizeof(float), (void*)(3 * sizeof(float)));
			opcode{load_immediate, a(0)}.set_immediate(1),
			opcode{load_immediate, a(1)}.set_immediate(3),
			opcode{load_immediate, a(2)}.set_immediate(GL_FLOAT),
			opcode{load_immediate, a(3)}.set_immediate(GL_FALSE),
			opcode{load_immediate, a(4)}.set_immediate(6 * sizeof(float)),
			opcode{load_immediate, a(5)}.set_immediate(3 * sizeof(float)),
			opcode{ffi::call, 0, t(4), t(5)},
			// glEnableVertexAttribArray(1);
			opcode{ffi::call, 0, t(6), 120}, // 120 == void(*)(uint32_t)
			opcode{ffi::free_interface, 0, t(5)},

			// float view[16](t4), projection[16](t5);
			opcode{stack_push_immediate}.set_immediate(16 * sizeof(float)),
			opcode{unsafe::pointer_to_stack, t(4)},
			opcode{stack_push_immediate}.set_immediate(16 * sizeof(float)),
			opcode{unsafe::pointer_to_stack, t(5)},
			// Save registers
			opcode{stack_push_immediate}.set_immediate(6 * sizeof(uint64_t)),
			opcode{load_immediate, t(6)}.set_immediate(0 * sizeof(uint64_t)),
			opcode{stack_store_u64, 0, t(0), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(1 * sizeof(uint64_t)),
			opcode{stack_store_u64, 0, t(1), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(2 * sizeof(uint64_t)),
			opcode{stack_store_u64, 0, t(2), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(3 * sizeof(uint64_t)),
			opcode{stack_store_u64, 0, t(3), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(4 * sizeof(uint64_t)),
			opcode{stack_store_u64, 0, t(4), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(5 * sizeof(uint64_t)),
			opcode{stack_store_u64, 0, t(5), t(6)},
			// mat4_translate(view(t4), 0.0f, 0.0f, -3.0f) [uses t0, t1, t2, t3, t4]
			opcode{add, a(0), t(4)},
			opcode{load_immediate, a(1)}.set_immediate_f32(0),
			opcode{load_immediate, a(2)}.set_immediate_f32(0),
			opcode{load_immediate, a(3)}.set_immediate_f32(-3),
			opcode{jump_to, return_address, 201}, // 201 == mat4_translate
			// mat4_perspective(projection(t5), 45.0f, 800.0f/600.0f, 0.1f, 100.0f); [uses t0, t1, t2, t3, t4]
			opcode{add, a(0), t(5)},
			opcode{load_immediate, a(1)}.set_immediate_f32(45),
			opcode{load_immediate, a(2)}.set_immediate_f32(800.0/600),
			opcode{load_immediate, a(3)}.set_immediate_f32(.1),
			opcode{load_immediate, a(4)}.set_immediate_f32(100),
			opcode{jump_to, return_address, 207}, // 207 == mat4_perspective
			// Restore registers
			opcode{load_immediate, t(6)}.set_immediate(5 * sizeof(uint64_t)),
			opcode{stack_load_u64, t(5), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(4 * sizeof(uint64_t)),
			opcode{stack_load_u64, t(4), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(3 * sizeof(uint64_t)),
			opcode{stack_load_u64, t(3), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(2 * sizeof(uint64_t)),
			opcode{stack_load_u64, t(2), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(1 * sizeof(uint64_t)),
			opcode{stack_load_u64, t(1), t(6)},
			opcode{load_immediate, t(6)}.set_immediate(0 * sizeof(uint64_t)),
			opcode{stack_load_u64, t(0), t(6)},
			opcode{stack_pop_immediate}.set_immediate(6 * sizeof(uint64_t)),

			// 227 = glfwWindowShouldClose
			opcode{load_immediate, 227}.set_host_pointer_lower_immediate((void*)glfwWindowShouldClose),
			opcode{load_upper_immediate, 227}.set_host_pointer_upper_immediate((void*)glfwWindowShouldClose),
			// 127 = int32_t(*)(void*)
			opcode{ffi::push_type_i32},
			opcode{ffi::push_type_pointer},
			opcode{ffi::create_interface, 127},
			// 228 = glfwPollEvents
			opcode{load_immediate, 228}.set_host_pointer_lower_immediate((void*)glfwPollEvents),
			opcode{load_upper_immediate, 228}.set_host_pointer_upper_immediate((void*)glfwPollEvents),
			// 229 = glClearColor
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(clear_color),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(clear_color),
			opcode{ffi::call_with_return, 229, 226, 126},
			// 129 = void(*)(float, float, float, float)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_f32},
			opcode{ffi::push_type_f32},
			opcode{ffi::push_type_f32},
			opcode{ffi::push_type_f32},
			opcode{ffi::create_interface, 129},
			// 230 = glClear // uses 120 == void(*)(uint32_t)
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(clear),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(clear),
			opcode{ffi::call_with_return, 230, 226, 126},
			// 231 = glUseProgram // uses 120 == void(*)(uint32_t)
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(use_program),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(use_program),
			opcode{ffi::call_with_return, 231, 226, 126},
			// 232 = glGetUniformLocation
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(get_uniform_location),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(get_uniform_location),
			opcode{ffi::call_with_return, 232, 226, 126},
			// 132 = uint32_t(*)(uint32_t, void*)
			opcode{ffi::push_type_f32},
			opcode{ffi::push_type_f32},
			opcode{ffi::push_type_pointer},
			opcode{ffi::create_interface, 132},
			// 233 = glUniformMatrix4fv
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(uniform_matrix4fv),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(uniform_matrix4fv),
			opcode{ffi::call_with_return, 233, 226, 126},
			// 133 = void(*)(uint32_t, int32_t, uint32_t, void*)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_i32},
			opcode{ffi::push_type_u32},
			opcode{ffi::push_type_pointer},
			opcode{ffi::create_interface, 133},
			// 134 = double(*)()
			opcode{ffi::push_type_f64},
			opcode{ffi::create_interface, 134},
			// 235 = glDrawArrays
			opcode{load_immediate, a(0)}.set_host_pointer_lower_immediate(draw_arrays),
			opcode{load_upper_immediate, a(0)}.set_host_pointer_upper_immediate(draw_arrays),
			opcode{ffi::call_with_return, 235, 226, 126},
			// 135 = void(*)(uint32_t, int32_t, int32_t)
			opcode{ffi::push_type_void},
			opcode{ffi::push_type_i32},
			opcode{ffi::push_type_i32},
			opcode{ffi::push_type_i32},
			opcode{ffi::create_interface, 135},
			// 236 = glfwSwapBuffers
			opcode{load_immediate, 236}.set_host_pointer_lower_immediate((void*)glfwSwapBuffers),
			opcode{load_upper_immediate, 236}.set_host_pointer_upper_immediate((void*)glfwSwapBuffers),


			// while(true)
			opcode{jump_relative_immediate, 224}.set_immediate_signed(1), // Label top of loop!
				// glfwPollEvents();
				opcode{ffi::call, 0, 228, 125}, // 125 == void(*)()
				// glClearColor(0.1f, 0.1f, 0.15f, 1.0f);
				opcode{load_immediate, a(0)}.set_immediate_f32(.1),
				opcode{load_immediate, a(1)}.set_immediate_f32(.1),
				opcode{load_immediate, a(2)}.set_immediate_f32(.15),
				opcode{load_immediate, a(3)}.set_immediate_f32(1),
				opcode{ffi::call, 0, 229, 129},
				// glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
				opcode{load_immediate, a(0)}.set_immediate(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT),
				opcode{ffi::call, 0, 230, 120}, // 120 == void(*)(uint32_t)
				// glUseProgram(shaderProgram(t1))
				opcode{add, a(0), t(1)},
				opcode{ffi::call, 0, 231, 120}, // 120 == void(*)(uint32_t)

				// a0 = glGetUniformLocation(t(1), "view");
				opcode{add, a(0), t(1)},
				opcode{load_immediate, a(1)}.set_host_pointer_lower_immediate(view),
				opcode{load_upper_immediate, a(1)}.set_host_pointer_upper_immediate(view),
				opcode{ffi::call_with_return, a(0), 232, 132},
				// uniform_matrix4fv(a0, 1, GL_FALSE, view(t4));
				opcode{load_immediate, a(1)}.set_immediate(1),
				opcode{load_immediate, a(2)}.set_immediate(GL_FALSE),
				opcode{add, a(3), t(4)},
				opcode{ffi::call, 0, 233, 133},

				// a0 = glGetUniformLocation(t(1), "projection");
				opcode{add, a(0), t(1)},
				opcode{load_immediate, a(1)}.set_host_pointer_lower_immediate(projection),
				opcode{load_upper_immediate, a(1)}.set_host_pointer_upper_immediate(projection),
				opcode{ffi::call_with_return, a(0), 232, 132},
				// uniform_matrix4fv(t6, 1, GL_FALSE, projection(t5));
				opcode{load_immediate, a(1)}.set_immediate(1),
				opcode{load_immediate, a(2)}.set_immediate(GL_FALSE),
				opcode{add, a(3), t(5)},
				opcode{ffi::call, 0, 233, 133},

				// t6 = (float)glfwGetTime()
				opcode{load_immediate, t(6)}.set_host_pointer_lower_immediate((void*)glfwGetTime),
				opcode{load_upper_immediate, t(6)}.set_host_pointer_upper_immediate((void*)glfwGetTime),
				opcode{ffi::call_with_return, t(6), t(6), 134},
				opcode{convert_f64_to_f32, t(6), t(6)},

				// i(t7) = 0
				opcode{add, t(7), zero},
				// t8 = loop top
				opcode{jump_relative_immediate, t(8)}.set_immediate_signed(1),
					// translatedMat(t9) = sp (16 floats)
					opcode{stack_push_immediate}.set_immediate_signed(16 * sizeof(float)),
					opcode{unsafe::pointer_to_stack, t(9)},
					// rotateMat(t10) = sp (16 floats)
					opcode{stack_push_immediate}.set_immediate_signed(16 * sizeof(float)),
					opcode{unsafe::pointer_to_stack, t(10)},
					// model(t11) = sp (16 floats)
					opcode{stack_push_immediate}.set_immediate_signed(16 * sizeof(float)),
					opcode{unsafe::pointer_to_stack, t(11)},

					// Save t0-t9 to stack
					opcode{stack_push_immediate}.set_immediate_signed(10 * sizeof(uint64_t)),
					opcode{load_immediate, t(13)}.set_immediate(0 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(0), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(1 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(1), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(2 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(2), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(3 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(3), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(4 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(4), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(5 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(5), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(6 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(6), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(7 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(7), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(8 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(8), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(9 * sizeof(uint64_t)),
					opcode{stack_store_u64, 0, t(9), t(13)},
					// t13 = positions(104) + i(t7) * sizeof(float)
					opcode{load_immediate, t(13)}.set_immediate(sizeof(float)),
					opcode{multiply, t(13), t(7), t(13)},
					opcode{add, t(13), t(13), 104}, // 104 == positions
					// mat4_translate(translateMat(t9), positions[i][0], positions[i][1], positions[i][2]);
					opcode{add, a(0), t(9)},
					opcode{load_immediate, a(1)}.set_immediate(0),
					opcode{add, a(1), t(13), a(1)},
					opcode{unsafe::pointer_to_register, t(14), a(1)},
					opcode{unsafe::copy_memory_immediate, t(14), a(1)}.set_branch_immediate(sizeof(float)),
					opcode{load_immediate, a(2)}.set_immediate(1),
					opcode{add, a(2), t(13), a(2)},
					opcode{unsafe::pointer_to_register, t(14), a(2)},
					opcode{unsafe::copy_memory_immediate, t(14), a(2)}.set_branch_immediate(sizeof(float)),
					opcode{load_immediate, a(3)}.set_immediate(2),
					opcode{add, a(3), t(13), a(3)},
					opcode{unsafe::pointer_to_register, t(14), a(3)},
					opcode{unsafe::copy_memory_immediate, t(14), a(3)}.set_branch_immediate(sizeof(float)),
					opcode{jump_to, return_address, 201}, // 201 == mat4_translate
					// a1 = time(t6) * (30 + i(t7) * 10)
					opcode{load_immediate, t(13)}.set_immediate(10),
					opcode{multiply, t(13), t(7), t(13)},
					opcode{load_immediate, t(14)}.set_immediate(30),
					opcode{add, t(13), t(13), t(14)},
					opcode{convert_to_f32, t(13), t(13)},
					opcode{multiply_f32, a(1), t(13), t(6)},
					// mat4_rotate(rotateMat(t10), a1, 1.0f, 0.3f, 0.5f);
					opcode{add, a(0), t(10)},
						// a1 set
					opcode{load_immediate, a(2)}.set_immediate_f32(1),
					opcode{load_immediate, a(2)}.set_immediate_f32(.3),
					opcode{load_immediate, a(3)}.set_immediate_f32(.5),
					opcode{jump_to, return_address, 202}, // 202 == mat4_rotate
					// mat4_multiply(model(t11), translateMat(t9), rotateMat(t10));
					opcode{add, a(0), t(11)},
					opcode{load_immediate, t(13)}.set_immediate(9 * sizeof(uint64_t)),
					opcode{stack_load_u64, a(1), t(13)},
					opcode{add, a(2), t(10)},
					opcode{jump_to, return_address, 205}, // 205 == mat4_multiply

					// Restore registers from stack
					opcode{load_immediate, t(13)}.set_immediate(0 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(0), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(1 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(1), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(2 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(2), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(3 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(3), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(4 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(4), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(5 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(5), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(6 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(6), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(7 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(7), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(8 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(8), t(13)},
					opcode{load_immediate, t(13)}.set_immediate(9 * sizeof(uint64_t)),
					opcode{stack_load_u64, t(9), t(13)},
					opcode{stack_pop_immediate}.set_immediate_signed(10 * sizeof(uint64_t)),

					// a0 = glGetUniformLocation(t(1), "model");
					opcode{add, a(0), t(1)},
					opcode{load_immediate, a(1)}.set_host_pointer_lower_immediate(model),
					opcode{load_upper_immediate, a(1)}.set_host_pointer_upper_immediate(model),
					opcode{ffi::call_with_return, a(0), 232, 132},
					// uniform_matrix4fv(t6, 1, GL_FALSE, model(t11));
					opcode{load_immediate, a(1)}.set_immediate(1),
					opcode{load_immediate, a(2)}.set_immediate(GL_FALSE),
					opcode{add, a(3), t(11)},
					opcode{ffi::call, 0, 233, 133},

					// glDrawArrays(GL_TRIANGLES, 0, 36);
					opcode{load_immediate, a(0)}.set_immediate(GL_TRIANGLES),
					opcode{load_immediate, a(1)}.set_immediate(0),
					opcode{load_immediate, a(2)}.set_immediate(36),
					opcode{ffi::call, 0, 235, 135},

					// Pop matrices
					opcode{stack_push_immediate}.set_immediate_signed(3 * 16 * sizeof(float)),

					// i(t7)++
					opcode{load_immediate, t(13)}.set_immediate(1),
					opcode{add, t(7), t(7), t(13)},
					opcode{debug::breakpoint},
					// if (i < 4) continue
					opcode{load_immediate, t(13)}.set_immediate(4),
					opcode{set_if_less, t(13), t(7), t(13)},
					opcode{branch_to, 0, t(13), t(8)}, // t(8) == top of loop

				// glfwSwapBuffers(window(t0));
				opcode{add, a(0), t(0)},
				opcode{ffi::call, 0, 236, 128}, // 128 == void(*)(void*)
				// if(!glfwWindowShouldClose(window(t0))) continue
				opcode{ffi::call_with_return, t(1), 227, 127},
				opcode{set_if_equal, t(1), t(1), zero},
				opcode{branch_to, 0, t(1), 224}, // 224 == top of loop

			// glfwDestroyWindow(window(t0));
			opcode{load_immediate, t(1)}.set_host_pointer_lower_immediate((void*)glfwDestroyWindow),
			opcode{load_upper_immediate, t(1)}.set_host_pointer_upper_immediate((void*)glfwDestroyWindow),
			opcode{ffi::call, 0, t(1), 128}, // 128 == void(*)(void*)
			// glfwTerminate()
			opcode{ffi::call, 0, 225, 125},
			opcode{halt},
	};

	{
		registers_and_stack env = {};
		setup_environment(env, program, program + sizeof(program)/sizeof(program[0]));

		MIZU_START_FROM_ENVIRONMENT(program, env);
	}

	return 0;
}