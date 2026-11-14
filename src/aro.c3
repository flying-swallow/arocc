// Root module of the C3 port of Aro. Submodules live in src/*.c3.
module aro;


// Public facade for the module exports in src/aro.zig and src/backend.zig.
// The implementation stays in the focused modules below this namespace.
const String VERSION = "0.1.0-dev";

struct Version
{
	uint major;
	uint minor;
	uint patch;
	String pre;
	String build;
}

const Version VERSION_INFO = { .major = 0, .minor = 1, .patch = 0, .pre = "dev", .build = "" };

<* src/backend.zig's backend CallingConvention export. *>
enum CallingConvention : char (String name)
{
	C { "c" },
	STDCALL { "stdcall" },
	THISCALL { "thiscall" },
	VECTORCALL { "vectorcall" },
	FASTCALL { "fastcall" },
	REGCALL { "regcall" },
	RISCV_VECTOR { "riscv_vector" },
	AARCH64_SVE_PCS { "aarch64_sve_pcs" },
	AARCH64_VECTOR_PCS { "aarch64_vector_pcs" },
	ARM_AAPCS { "arm_aapcs" },
	ARM_AAPCS_VFP { "arm_aapcs_vfp" },
	X86_64_SYSV { "x86_64_sysv" },
	X86_64_WIN { "x86_64_win" },
}

// Type aliases for the Zig exports live in aro::api (src/api.c3): C3 makes
// root-module symbols visible inside every aro::* submodule, so aliases here
// would collide with the real types in the modules that import them.

// Returned by stage-0 stubs whose real implementation has not landed yet.
excuse UNSUPPORTED;

<*
 Result of an injected subprocess call. The callback allocates stdout/stderr
 with the Allocator argument; the caller frees both returned buffers.
 spawn_error is the fault that stopped the spawn when started is false; zero means none.
*>
struct ProcessResult
{
	bool started;
	bool exited;
	int exit_code;
	String stdout;
	String stderr;
	fault spawn_error;
}

alias ProcessRunFn = fn ProcessResult(void* ctx, Allocator a, String[] argv);

<* Borrowed process runner; `ctx` and callback must outlive its use. *>
struct ProcessService
{
	void* ctx;
	ProcessRunFn run;
}
