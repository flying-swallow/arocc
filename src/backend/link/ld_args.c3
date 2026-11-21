// Parser and lookup helpers for the subset of GNU ld arguments used by the
// in-process ELF linker.
module aro::backend::link;
import aro::frontend::c::diagnostics;
import std::collections::list;
import std::core::string;
import aro::toolchain::discovery;

enum OutputKind : char
{
	EXEC,
	PIE,
	SHARED,
	STATIC,
	STATIC_PIE,
}

enum LinkItemKind : char
{
	FILE,
	LIBRARY,
	GROUP_START,
	GROUP_END,
}

<* One ordered file or library input. `value` is borrowed from the argv slice. *>
struct LinkItem
{
	LinkItemKind kind;
	String value;
	bool exact;
	bool as_needed;
	bool static_only;
	bool whole_archive;
}

<*
 Parsed linker options and ordered inputs. Strings in this plan borrow from the
 caller's argv; the plan owns only its list storage. `eh_frame_hdr`,
 `build_id`, and `hash_style` are recorded for the later output writer. That
 writer must emit PT_GNU_EH_FRAME / `.eh_frame_hdr` and DT_GNU_HASH versus
 DT_HASH.
*>
struct LinkPlan
{
	Allocator allocator;
	String output;
	OutputKind kind;
	String emulation;
	bool has_emulation;
	String dynamic_linker;
	bool has_dynamic_linker;
	bool no_dynamic_linker;
	String entry;
	bool has_entry;
	List{LinkItem} inputs;
	List{String} search_dirs;
	bool z_now;
	bool z_relro;
	bool z_text;
	bool z_noexecstack;
	bool z_execstack;
	ulong max_page_size;
	bool has_max_page_size;
	ulong common_page_size;
	bool has_common_page_size;
	bool export_dynamic;
	bool strip_all;
	bool discard_locals;
	bool eh_frame_hdr;
	bool build_id;
	String hash_style;
	bool has_hash_style;
	String unsupported_arg;
}

fn void LinkPlan.init(&self, Allocator a)
{
	*self = { .allocator = a, .output = "a.out", .kind = EXEC };
	self.inputs.init(a);
	self.search_dirs.init(a);
}

<* List storage is released; argv strings referenced by the plan are borrowed. *>
fn void LinkPlan.free(&self)
{
	self.inputs.free();
	self.search_dirs.free();
	*self = {};
}

fn void reset_plan(LinkPlan* plan)
{
	plan.inputs.clear();
	plan.search_dirs.clear();
	plan.kind = EXEC;
	plan.output = "a.out";
	plan.emulation = "";
	plan.has_emulation = false;
	plan.dynamic_linker = "";
	plan.has_dynamic_linker = false;
	plan.no_dynamic_linker = false;
	plan.entry = "";
	plan.has_entry = false;
	plan.z_now = false;
	plan.z_relro = false;
	plan.z_text = false;
	plan.z_noexecstack = false;
	plan.z_execstack = false;
	plan.max_page_size = 0;
	plan.has_max_page_size = false;
	plan.common_page_size = 0;
	plan.has_common_page_size = false;
	plan.export_dynamic = false;
	plan.strip_all = false;
	plan.discard_locals = false;
	plan.eh_frame_hdr = false;
	plan.build_id = false;
	plan.hash_style = "";
	plan.has_hash_style = false;
	plan.unsupported_arg = "";
}

<* @return? MALFORMED_LD_ARGS *>
fn void? malformed_ld_args(Diagnostics* d, String reason)
{
	@link_err(d, Diagnostic.MALFORMED_LD_ARGS, reason)!;
	return MALFORMED_LD_ARGS~;
}

fn void? missing_ld_value(Diagnostics* d, String flag)
{
	return malformed_ld_args(d, string::tformat("'%s' requires a value", flag))!;
}

<* @return? UNSUPPORTED_LD_ARG *>
fn void? unsupported_ld_arg(LinkPlan* plan, Diagnostics* d, String arg)
{
	plan.unsupported_arg = arg;
	@link_err(d, Diagnostic.UNSUPPORTED_LD_ARG, arg)!;
	return UNSUPPORTED_LD_ARG~;
}

fn bool next_arg(String[] args, usz* index, String* value)
{
	if (*index + 1 >= args.len) return false;
	(*index)++;
	*value = args[*index];
	return true;
}

fn bool parse_unsigned(String text, ulong* value)
{
	if (text.len == 0) return false;
	uint base = 10;
	usz at = 0;
	if (text.len >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X'))
	{
		base = 16;
		at = 2;
		if (at == text.len) return false;
	}
	ulong result = 0;
	for (; at < text.len; at++)
	{
		char c = text[at];
		uint digit;
		if (c >= '0' && c <= '9') { digit = (uint)(c - '0'); }
		else if (base == 16 && c >= 'a' && c <= 'f') { digit = (uint)(c - 'a') + 10; }
		else if (base == 16 && c >= 'A' && c <= 'F') { digit = (uint)(c - 'A') + 10; }
		else { return false; }
		if (digit >= base || result > (ulong::max - digit) / base) return false;
		result = result * base + digit;
	}
	*value = result;
	return true;
}

fn bool parse_z_option(LinkPlan* plan, String value)
{
	if (value == "relro") { plan.z_relro = true; }
	else if (value == "norelro") { plan.z_relro = false; }
	else if (value == "now") { plan.z_now = true; }
	else if (value == "lazy") { plan.z_now = false; }
	else if (value == "noexecstack") { plan.z_noexecstack = true; plan.z_execstack = false; }
	else if (value == "execstack") { plan.z_execstack = true; plan.z_noexecstack = false; }
	else if (value == "text") { plan.z_text = true; }
	else if (value == "notext") { plan.z_text = false; }
	else if (value.starts_with("max-page-size="))
	{
		ulong size;
		if (!parse_unsigned(value[14..], &size)) return false;
		plan.has_max_page_size = true;
		plan.max_page_size = size;
	}
	else if (value.starts_with("common-page-size="))
	{
		ulong size;
		if (!parse_unsigned(value[17..], &size)) return false;
		plan.has_common_page_size = true;
		plan.common_page_size = size;
	}
	else { return false; }
	return true;
}

fn void append_link_item(LinkPlan* plan, LinkItemKind kind, String value,
	bool as_needed, bool static_only, bool whole_archive, bool exact = false)
{
	plan.inputs.push({
		.kind = kind,
		.value = value,
		.exact = exact,
		.as_needed = as_needed,
		.static_only = static_only,
		.whole_archive = whole_archive,
	});
}

fn String library_filename(Allocator a, String name, String suffix)
{
	String prefix = "lib".concat(a, name);
	String filename = prefix.concat(a, suffix);
	alloc::free(a, prefix.ptr);
	return filename;
}

<*
 Parse the supported subset of GNU ld argv into `plan`. Parsed strings borrow
 from `args`; call `LinkPlan.free()` to release the plan's owned list storage.
 `-r` is currently unsupported because the in-process linker does not produce
 relocatable output; the compiler's argument builder can still omit it.

 @return? link::MALFORMED_LD_ARGS, link::UNSUPPORTED_LD_ARG
*>
fn void? parse_ld_args(LinkPlan* plan, Diagnostics* d, String[] args)
{
	reset_plan(plan);
	bool as_needed = false;
	bool static_only = false;
	bool whole_archive = false;
	bool in_group = false;
	bool is_static = false;
	bool is_pie = false;
	bool is_shared = false;
	for (usz i = 0; i < args.len; i++)
	{
		String arg = args[i];
		if (arg == "--") return unsupported_ld_arg(plan, d, arg)!;
		if (arg == "-L" || arg == "-l" || arg == "-o" || arg == "-e" || arg == "-m" ||
			arg == "-dynamic-linker" || arg == "-z" || arg == "--hash-style")
		{
			String value;
			if (!next_arg(args, &i, &value)) return missing_ld_value(d, arg)!;
			if (value.len == 0) return missing_ld_value(d, arg)!;
			if (arg == "-L") { plan.search_dirs.push(value); continue; }
			if (arg == "-l")
			{
				bool exact = value.starts_with(":");
				String name = exact ? value[1..] : value;
				if (name.len == 0) return missing_ld_value(d, "-l")!;
				append_link_item(plan, LIBRARY, name, as_needed, static_only, whole_archive, exact);
				continue;
			}
			if (arg == "-o") { plan.output = value; continue; }
			if (arg == "-e") { plan.entry = value; plan.has_entry = true; continue; }
			if (arg == "-m")
			{
				if (value != "elf_x86_64") return unsupported_ld_arg(plan, d, arg)!;
				plan.emulation = value;
				plan.has_emulation = true;
				continue;
			}
			if (arg == "-dynamic-linker") { plan.dynamic_linker = value; plan.has_dynamic_linker = true; continue; }
			if (arg == "--hash-style")
			{
				if (value != "gnu" && value != "both" && value != "sysv")
				{
					return malformed_ld_args(d, string::tformat("invalid --hash-style value '%s'", value))!;
				}
				plan.hash_style = value;
				plan.has_hash_style = true;
				continue;
			}
			if (!parse_z_option(plan, value))
			{
				if (value.starts_with("max-page-size=") || value.starts_with("common-page-size="))
				{
					return malformed_ld_args(d, string::tformat("%s has an invalid size", arg))!;
				}
				return unsupported_ld_arg(plan, d, arg)!;
			}
			continue;
		}
		if (arg.starts_with("-L"))
		{
			String path = arg[2..];
			if (path.len == 0) return missing_ld_value(d, "-L")!;
			plan.search_dirs.push(path);
			continue;
		}
		if (arg.starts_with("-l:"))
		{
			String name = arg[3..];
			if (name.len == 0) return missing_ld_value(d, "-l:")!;
			append_link_item(plan, LIBRARY, name, as_needed, static_only, whole_archive, true);
			continue;
		}
		if (arg.starts_with("-l"))
		{
			String name = arg[2..];
			if (name.len == 0) return missing_ld_value(d, "-l")!;
			append_link_item(plan, LIBRARY, name, as_needed, static_only, whole_archive);
			continue;
		}
		if (arg.starts_with("-o"))
		{
			String value = arg[2..];
			if (value.starts_with("=")) value = value[1..];
			if (value.len == 0) return missing_ld_value(d, "-o")!;
			plan.output = value;
			continue;
		}
		if (arg == "--output" || arg == "--entry" || arg == "--emulation" || arg == "--dynamic-linker")
		{
			String value;
			if (!next_arg(args, &i, &value)) return missing_ld_value(d, arg)!;
			if (value.len == 0) return missing_ld_value(d, arg)!;
			if (arg == "--output") { plan.output = value; }
			else if (arg == "--entry") { plan.entry = value; plan.has_entry = true; }
			else if (arg == "--emulation")
			{
				if (value != "elf_x86_64") return unsupported_ld_arg(plan, d, "-m")!;
				plan.emulation = value; plan.has_emulation = true;
			}
			else { plan.dynamic_linker = value; plan.has_dynamic_linker = true; }
			continue;
		}
		if (arg.starts_with("--output="))
		{
			String value = arg[9..];
			if (value.len == 0) return missing_ld_value(d, "--output")!;
			plan.output = value;
			continue;
		}
		if (arg.starts_with("--entry="))
		{
			String value = arg[8..];
			if (value.len == 0) return missing_ld_value(d, "--entry")!;
			plan.entry = value; plan.has_entry = true;
			continue;
		}
		if (arg.starts_with("--emulation="))
		{
			String value = arg[12..];
			if (value.len == 0) return missing_ld_value(d, "--emulation")!;
			if (value != "elf_x86_64") return unsupported_ld_arg(plan, d, "-m")!;
			plan.emulation = value; plan.has_emulation = true;
			continue;
		}
		if (arg.starts_with("--dynamic-linker="))
		{
			String value = arg[17..];
			if (value.len == 0) return missing_ld_value(d, "--dynamic-linker")!;
			plan.dynamic_linker = value; plan.has_dynamic_linker = true;
			continue;
		}
		if (arg.starts_with("--hash-style="))
		{
			String value = arg[13..];
			if (value.len == 0) return missing_ld_value(d, "--hash-style")!;
			if (value != "gnu" && value != "both" && value != "sysv")
			{
				return malformed_ld_args(d, string::tformat("invalid --hash-style value '%s'", value))!;
			}
			plan.hash_style = value; plan.has_hash_style = true;
			continue;
		}
		if (arg.starts_with("-m") && arg.len > 2)
		{
			String value = arg[2..];
			if (value.starts_with("=")) value = value[1..];
			if (value.len == 0) return missing_ld_value(d, "-m")!;
			if (value != "elf_x86_64") return unsupported_ld_arg(plan, d, "-m")!;
			plan.emulation = value; plan.has_emulation = true;
			continue;
		}
		if (arg.starts_with("-dynamic-linker="))
		{
			String value = arg[16..];
			if (value.len == 0) return missing_ld_value(d, "-dynamic-linker")!;
			plan.dynamic_linker = value; plan.has_dynamic_linker = true;
			continue;
		}
		if (arg.starts_with("-z") && arg.len > 2)
		{
			String value = arg[2..];
			if (value.starts_with("=")) value = value[1..];
			if (value.len == 0) return missing_ld_value(d, "-z")!;
			if (!parse_z_option(plan, value))
			{
				if (value.starts_with("max-page-size=") || value.starts_with("common-page-size="))
				{
					return malformed_ld_args(d, "-z has an invalid size")!;
				}
				return unsupported_ld_arg(plan, d, "-z")!;
			}
			continue;
		}
		if (arg == "-Bstatic") { static_only = true; continue; }
		if (arg == "-Bdynamic") { static_only = false; continue; }
		if (arg == "-dn" || arg == "-non_shared") { static_only = true; continue; }
		if (arg == "-dy" || arg == "-call_shared") { static_only = false; continue; }
		if (arg == "--as-needed") { as_needed = true; continue; }
		if (arg == "--no-as-needed") { as_needed = false; continue; }
		if (arg == "--whole-archive") { whole_archive = true; continue; }
		if (arg == "--no-whole-archive") { whole_archive = false; continue; }
		if (arg == "--start-group" || arg == "-(")
		{
			if (in_group) return malformed_ld_args(d, "nested --start-group")!;
			in_group = true;
			append_link_item(plan, GROUP_START, "", as_needed, static_only, whole_archive);
			continue;
		}
		if (arg == "--end-group" || arg == "-)")
		{
			if (!in_group) return malformed_ld_args(d, "--end-group without --start-group")!;
			in_group = false;
			append_link_item(plan, GROUP_END, "", as_needed, static_only, whole_archive);
			continue;
		}
		if (arg == "-pie" || arg == "--pie" || arg == "--pic-executable") { is_pie = true; continue; }
		if (arg == "-no-pie" || arg == "-nopie" || arg == "--no-pie") { is_pie = false; continue; }
		if (arg == "-static-pie") { is_static = true; is_pie = true; static_only = true; plan.no_dynamic_linker = true; continue; }
		if (arg == "-static") { is_static = true; static_only = true; continue; }
		if (arg == "-shared" || arg == "-Bshareable") { is_shared = true; continue; }
		if (arg == "--no-dynamic-linker") { plan.no_dynamic_linker = true; continue; }
		if (arg == "--eh-frame-hdr") { plan.eh_frame_hdr = true; continue; }
		if (arg == "--build-id") { plan.build_id = true; continue; }
		if (arg.starts_with("--build-id="))
		{
			String style = arg[11..];
			if (style.len == 0) return missing_ld_value(d, "--build-id")!;
			plan.build_id = style != "none";
			continue;
		}
		if (arg == "-X" || arg == "--discard-locals") { plan.discard_locals = true; continue; }
		if (arg == "-export-dynamic" || arg == "--export-dynamic" || arg == "-E") { plan.export_dynamic = true; continue; }
		if (arg == "-s" || arg == "--strip-all") { plan.strip_all = true; continue; }
		if (arg.starts_with("-e") && arg.len > 2)
		{
			plan.entry = arg[2..]; plan.has_entry = true;
			continue;
		}
		if (arg == "-r")
		{
			// TODO: Implement relocatable output before accepting -r; do not silently omit it.
			return unsupported_ld_arg(plan, d, arg)!;
		}
		if (arg.starts_with("-")) return unsupported_ld_arg(plan, d, arg)!;
		append_link_item(plan, FILE, arg, as_needed, static_only, whole_archive);
	}
	if (in_group) return malformed_ld_args(d, "--start-group without --end-group")!;
	if (is_shared && is_static) return unsupported_ld_arg(plan, d, "-shared with -static")!;
	if (is_shared) { plan.kind = SHARED; }
	else if (is_static && is_pie) { plan.kind = STATIC_PIE; }
	else if (is_static) { plan.kind = STATIC; }
	else if (is_pie) { plan.kind = PIE; }
	else { plan.kind = EXEC; }
	return;
}

<*
 Find a library in `plan.search_dirs` order. Within each directory a dynamic
 lookup tries `libNAME.so` before `libNAME.a`; a static-only lookup tries only
 `libNAME.a`. Exact (`-l:FILE`) lookups use the supplied filename as-is.
 The returned path is allocated by `a` and must be freed by the caller.

 @return? link::LIBRARY_NOT_FOUND
*>
fn String? find_library(Allocator a, LinkFs* fs, LinkPlan* plan, String name,
	bool exact, bool static_only)
{
	foreach (dir : plan.search_dirs)
	{
		if (exact)
		{
			String candidate = discovery::join(a, { dir, name });
			if (fs.exists(candidate)) return candidate;
			alloc::free(a, candidate.ptr);
			continue;
		}
		if (!static_only)
		{
			String shared_name = library_filename(a, name, ".so");
			String candidate = discovery::join(a, { dir, shared_name });
			alloc::free(a, shared_name.ptr);
			if (fs.exists(candidate)) return candidate;
			alloc::free(a, candidate.ptr);
		}
		String static_name = library_filename(a, name, ".a");
		String candidate = discovery::join(a, { dir, static_name });
		alloc::free(a, static_name.ptr);
		if (fs.exists(candidate)) return candidate;
		alloc::free(a, candidate.ptr);
	}
	return LIBRARY_NOT_FOUND~;
}
