// Darwin SDK and include discovery ported from src/aro/Toolchain/Darwin.zig.
// xcrun is always invoked through the borrowed process service so tests can
// exercise status and output handling without a host Apple toolchain.
module aro::toolchain::darwin;
import aro::toolchain, aro::toolchain::discovery, aro::compilation;
import aro::target;
import std::collections::list;

excuse NO_PROCESS_SERVICE;
excuse XCRUN_FAILED;
excuse INVALID_XCRUN_OUTPUT;

enum Sdk : char (String name)
{
	DRIVERKIT { "driverkit" },
	IPHONEOS { "iphoneos" },
	IPHONESIMULATOR { "iphonesimulator" },
	MACOSX { "macosx" },
	APPLETVOS { "appletvos" },
	APPLETVSIMULATOR { "appletvsimulator" },
	XROS { "xros" },
	XRSIMULATOR { "xrsimulator" },
	WATCHOS { "watchos" },
	WATCHSIMULATOR { "watchsimulator" },
}

fn Sdk from_target(Target* t)
{
	switch (t.os.tag)
	{
		case DRIVERKIT: return DRIVERKIT;
		case IOS: return t.abi == SIMULATOR ? IPHONESIMULATOR : IPHONEOS;
		case MACCATALYST:
		case MACOS: return MACOSX;
		case TVOS: return t.abi == SIMULATOR ? APPLETVSIMULATOR : APPLETVOS;
		case VISIONOS: return t.abi == SIMULATOR ? XRSIMULATOR : XROS;
		case WATCHOS: return t.abi == SIMULATOR ? WATCHSIMULATOR : WATCHOS;
		default: return MACOSX;
	}
}

<*
 Run `xcrun --sdk <sdk> <arg>`. The returned path is copied into `a` and
 validated through the injected filesystem. Output buffers returned by the
 process service are freed here, including on every failure path.
*>
fn String? xcrun_path(Allocator a, discovery::Env* env, Sdk sdk, String arg)
{
	if (!env.process.run) return NO_PROCESS_SERVICE~;
	ProcessResult result = env.process.run(env.process.ctx, a, { "xcrun", "--sdk", sdk.name, arg });
	defer
	{
		if (result.stdout.ptr) alloc::free(a, result.stdout.ptr);
		if (result.stderr.ptr) alloc::free(a, result.stderr.ptr);
	}
	if (!result.started || !result.exited || result.exit_code != 0) return XCRUN_FAILED~;
	if (result.stderr.len != 0) return XCRUN_FAILED~;
	// Zig requires exactly one nonempty output line terminated by a newline.
	usz nl = 0;
	while (nl < result.stdout.len && result.stdout[nl] != '\n') nl++;
	if (nl == 0 || nl == result.stdout.len || nl + 1 != result.stdout.len) return INVALID_XCRUN_OUTPUT~;
	String path = result.stdout[:nl].copy(a);
	if (!env.exists(path)) { alloc::free(a, path.ptr); return INVALID_XCRUN_OUTPUT~; }
	return path;
}

<* Zig Darwin.defineSystemIncludes, preserving include directory order. *>
fn void? define_system_includes(Toolchain* tc, discovery::Env* env, List{IncludeDir}* includes,
	bool host_is_darwin)
{
	if (tc.opts.nostdinc) return;
	String sdk_path = "";
	bool owns_sdk_path = false;
	defer if (owns_sdk_path) alloc::free(tc.a, sdk_path.ptr);
	if (!tc.opts.nostdlibinc)
	{
		String sysroot = tc.get_sysroot();
		if (sysroot.len) { sdk_path = sysroot; }
		else if (host_is_darwin)
		{
			sdk_path = xcrun_path(tc.a, env, from_target(&env.target), "--show-sdk-path")!;
			owns_sdk_path = true;
		}
		tc.add_system_include_dir_joined({ "usr", "local", "include" }, includes)!!;
	}
	if (sdk_path.len) tc.add_system_include_dir_joined({ sdk_path, "usr", "local", "include" }, includes)!!;
	if (!tc.opts.nobuiltininc) tc.add_builtin_include_dir(includes)!;
	if (sdk_path.len) tc.add_system_include_dir_joined({ sdk_path, "usr", "include" }, includes)!!;
}
