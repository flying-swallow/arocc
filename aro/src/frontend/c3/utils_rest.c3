// The c3c src/utils helpers sema calls that are not ported elsewhere:
// file_utils.c, time.c, compiler_tests/benchmark.c, stringutils.c / lib.h
// `StringSlice` helpers and lib.h `a5hash`.
//
// Deviations from c3c:
// - `StringSlice { ptr, len }` is a C3 String.
// - `BenchTime` is a std::time Clock.
// - `char **out` parameters are `String*`.
// - POSIX only (the PLATFORM_WINDOWS branches are dropped). `popen` /
//   `pclose` / `chdir` / `getcwd` / `readlink` are declared here (std has no
//   popen binding). `file_add_wildcard_files` lists directories with
//   std::io::path::ls instead of opendir / readdir / stat.
// - `file_read_binary` and `a5hash` read through bytes, so unaligned keys
//   are fine; results equal c3c's on little-endian targets.
// - `execute_cmd_failable` (needed by execute_cmd and compile_and_invoke) is
//   ported here too.
module aro::frontend::c3::compiler;
import std::time::clock, std::io, std::io::file, std::io::path, libc;

extern fn void* posix_popen(ZString command, ZString mode) @cname("popen");
extern fn CInt posix_pclose(void* stream) @cname("pclose");
extern fn CInt posix_chdir(ZString path) @cname("chdir");
extern fn ZString posix_getcwd(char* buf, usz size) @cname("getcwd");

alias StringSlice = String;
alias BenchTime = Clock;

// ---------------------------------------------------------------------------
// compiler_tests/benchmark.c

Clock bench_begin_time;

fn void bench_begin()
{
	bench_begin_time = clock::now();
}

fn double bench_mark() => benchmark(bench_begin_time);

fn BenchTime benchstart() => clock::now();

fn double benchmark(BenchTime start)
{
	return (double)(long)start.to_now() / 1_000_000_000.0;
}

// ---------------------------------------------------------------------------
// stringutils.c / lib.h StringSlice

fn StringSlice slice_from_string(String data) @inline => data;

fn bool slice_strcmp(StringSlice slice, String other) @inline => slice == other;

fn StringSlice slice_next_token(StringSlice* slice, char separator)
{
	for (usz i = 0; i < slice.len; i++)
	{
		if ((*slice)[i] == separator)
		{
			StringSlice result = (*slice)[:i];
			*slice = (*slice)[i + 1..];
			return result;
		}
	}
	StringSlice result = *slice;
	*slice = (*slice)[slice.len..];
	return result;
}

fn void slice_trim(StringSlice* slice)
{
	usz i;
	for (i = 0; i < slice.len; i++)
	{
		if ((*slice)[i] != ' ') break;
	}
	*slice = (*slice)[i..];
	for (i = slice.len; i > 0; i--)
	{
		if ((*slice)[i - 1] != ' ') break;
	}
	*slice = (*slice)[:i];
}

// lib.h:300 (static)
fn void a5mul(ulong u, ulong v, ulong* lo, ulong* hi) @inline
{
	ulong ul = u & 0xFFFFFFFF;
	ulong vl = v & 0xFFFFFFFF;
	ulong t = ul * vl;
	ulong w3 = t & 0xFFFFFFFF;
	ulong k = t >> 32;

	u >>= 32;
	t = u * vl + k;
	k = t & 0xFFFFFFFF;
	ulong w1 = t >> 32;

	v >>= 32;
	t = ul * v + k;

	*hi = (u * v) + w1 + (t >> 32);
	*lo = (t << 32) + w3;
}

<* Little-endian unaligned loads for a5hash. *>
fn ulong a5_read64(char* p) @inline
{
	ulong r = 0;
	for (int i = 7; i >= 0; i--) r = (r << 8) | p[i];
	return r;
}

fn ulong a5_read32(char* p) @inline
{
	ulong r = 0;
	for (int i = 3; i >= 0; i--) r = (r << 8) | p[i];
	return r;
}

// lib.h:320
fn ulong a5hash(String key, uint len, ulong seed)
{
	ulong widened_len = (ulong)len;
	ulong seed1 = 0x243F6A8885A308D3 ^ widened_len;
	ulong seed2 = 0x452821E638D01377 ^ widened_len;
	ulong val10 = 0xAAAAAAAAAAAAAAAA;
	ulong val01 = 0x5555555555555555;
	ulong a;
	ulong b;
	char* scroll = key.ptr;
	char* end = key.ptr + len;

	a5mul(seed2 ^ (seed & val10), seed1 ^ (seed & val01), &seed1, &seed2);

	val10 ^= seed2;

	if (len > 3)
	{
		if (len > 16)
		{
			val01 ^= seed1;

			for (; end - scroll > 16; scroll += 16)
			{
				a5mul(a5_read64(scroll) ^ seed1, a5_read64(scroll + 8) ^ seed2, &seed1, &seed2);

				seed1 += val01;
				seed2 += val10;
			}

			a = a5_read64(scroll + (end - scroll) - 16);
			b = a5_read64(scroll + (end - scroll) - 8);
		}
		else
		{
			a = (a5_read32(scroll) << 32) | a5_read32(end - 4);
			b = (a5_read32(&scroll[(len >> 3) * 4]) << 32)
				| a5_read32(end - 4 - (sz)((len >> 3) * 4));
		}
	}
	else
	{
		a = len
			? ((ulong)scroll[0]
				| (len > 1 ? ((ulong)scroll[1] << 8) : 0)
				| (len > 2 ? ((ulong)scroll[2] << 16) : 0))
			: 0;
		b = 0;
	}

	a5mul(a ^ seed1, b ^ seed2, &seed1, &seed2);
	a5mul(val01 ^ seed1, seed2, &a, &b);

	return a ^ b;
}

// ---------------------------------------------------------------------------
// file_utils.c

// file_utils.c:194
fn bool dir_change(String path)
{
	@pool()
	{
		return posix_chdir(path.zstr_tcopy()) == 0;
	};
}

// file_utils.c:203 (static)
fn bool is_path_separator(char c) @inline => c == '/';

// file_utils.c:243
fn bool file_namesplit(String path, String* filename_ptr, String* directory_ptr)
{
	usz len = path.len;
	if (len == 0) return false;
	usz found_at = usz::max;
	for (usz i = len - 1; i > 0; i--)
	{
		if (is_path_separator(path[i]))
		{
			found_at = i;
			break;
		}
	}
	usz file_len = (found_at != usz::max) ? len - found_at - 1 : len;
	if (file_len == 1 && path[found_at + 1] == '.') return false;
	if (file_len == 2 && path[found_at + 1] == '.' && path[found_at + 2] == '.') return false;
	if (!file_len) return false;
	if (filename_ptr) *filename_ptr = str_copy(path[len - file_len:file_len]);
	if (!directory_ptr) return true;
	if (file_len < len)
	{
		usz dir_len = len - file_len;
		*directory_ptr = str_copy(path[:dir_len - 1]);
	}
	else
	{
		*directory_ptr = str_copy(".");
	}
	return true;
}

// file_utils.c:419
fn char* file_read_binary(String path, usz* size)
{
	usz max_read = *size;
	char[]? data = file::load(mem, path);
	if (catch data) return null;
	defer alloc::free(mem, data.ptr);
	usz file_size = data.len;
	if (!file_size)
	{
		*size = 0;
		return calloc_arena(1);
	}
	if (file_size > max_read) file_size = max_read;
	char* buffer = calloc_arena(file_size + 1);
	buffer[:file_size] = data[:file_size];
	buffer[file_size] = 0;
	*size = file_size;
	return buffer;
}

// file_utils.c:659
fn bool file_path_is_relative(String file_name)
{
	usz len = file_name.len;
	if (!len) return false;

	// returns !full_path condition
	return file_name[0] != '/';
}

// file_utils.c:702
fn String file_append_path(String path, String name)
{
	usz path_len = path.len;
	if (!path_len) return str_dup(name);
	if (path[path_len - 1] == '/') return str_cat(path, name);
	return @str_printf("%s/%s", path, name);
}

// file_utils.c:593
fn bool file_has_suffix_in_list(String file_name, int name_len, String[] suffix_list, int suffix_count)
{
	for (int i = 0; i < suffix_count; i++)
	{
		String suffix = suffix_list[i];
		int len = (int)suffix.len;
		if (name_len < len + 1) continue;
		if (file_name[name_len - len:len] == suffix) return true;
	}
	return false;
}

// file_utils.c:947
fn String execute_cmd(String cmd, bool ignore_failure, String stdin_string, usz limit)
{
	String result = {};
	bool success = execute_cmd_failable(cmd, &result, stdin_string, limit);
	if (!success)
	{
		if (ignore_failure) return "";
		if (result.len)
		{
			io::eprintf("+-- Command output --------------------+\n");
			io::eprintf("%s\n", result);
			io::eprintf("+--------------------------------------+\n");
		}
		@error_exit("Failed to execute '%s'.", cmd);
	}
	return result;
}

// file_utils.c:965
fn bool execute_cmd_failable(String cmd, String* result, String stdin_string, usz limit)
{
	const int BUFSIZE = 1024;
	char[BUFSIZE] buffer;
	String output = "";
	if (stdin_string.ptr)
	{
		cmd = str_copy(cmd);
		scratch_buffer_clear();
		@scratch_buffer_printf("cat __c3temp.bin | %s", cmd);
		cmd = scratch_buffer_copy();
		if (catch file::save("__c3temp.bin", stdin_string)) @error_exit("Failed to create temporary file '__c3temp.bin' for stdin.");
	}
	void* process;
	@pool()
	{
		process = posix_popen(cmd.zstr_tcopy(), "r");
	};
	if (!process) return false;
	uint len = 0;
	while (libc::fgets(&buffer, BUFSIZE - 1, process))
	{
		String chunk = ((ZString)&buffer).str_view();
		if (limit)
		{
			if (len > limit)
			{
				output = str_cat(output, " ... [TRUNCATED]");
				break;
			}
			len += (uint)chunk.len;
		}
		output = str_cat(output, chunk);
	}
	int err = posix_pclose(process);
	if (stdin_string.ptr)
	{
		(void)file::delete("__c3temp.bin");
	}
	*result = str_copy(output.trim());
	return !err;
}

// file_utils.c (file_add_wildcard_files): only reached when a stdlib dir is set.
fn void file_add_wildcard_files(String[]* files, String path, bool recursive, String[] suffix_list, int suffix_count)
{
	usz len = path.len;
	if (len == 0)
	{
		path = "./";
		len = 2;
	}
	bool path_ends_with_slash = is_path_separator(path[len - 1]);
	@pool()
	{
		Path? dir = path::tnew(path);
		PathList? entries;
		if (try dir) entries = path::ls(tmem, dir);
		if (catch entries)
		{
			@error_exit("Can't open the directory '%s'. Please check the paths.", path);
		}
		foreach (entry : entries)
		{
			String name = (String)entry;
			usz namelen = name.len;
			if (namelen == 0 || name[0] == '.') continue;
			String format_path = path_ends_with_slash ? @str_printf("%s%s", path, name) : @str_printf("%s/%s", path, name);
			if (namelen < 3 || !file_has_suffix_in_list(name, (int)namelen, suffix_list, suffix_count))
			{
				Path? new_path = path::tnew(format_path);
				if (catch new_path) continue;
				bool is_directory = path::is_dir(new_path);
				if (is_directory && name[0] != '.' && recursive)
				{
					file_add_wildcard_files(files, format_path, recursive, suffix_list, suffix_count);
				}
				continue;
			}
			@vec_add(files, format_path);
		}
	};
}

// ---------------------------------------------------------------------------
// time.c

<* time.c: localtime for now. *>
fn Tm local_tm() @local
{
	Time_t rawtime;
	libc::time(&rawtime);
	Tm timeinfo;
	libc::localtime_r(&rawtime, &timeinfo);
	return timeinfo;
}

// time.c:7
fn String time_get()
{
	Tm timeinfo = local_tm();
	scratch_buffer_clear();
	@scratch_buffer_printf("%02d:%02d:%02d", timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);
	return scratch_buffer_copy();
}

// time.c:18
fn String date_get()
{
	Tm timeinfo = local_tm();
	scratch_buffer_clear();
	@scratch_buffer_printf("%02d-%02d-%02d", timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday);
	return scratch_buffer_copy();
}

// ---------------------------------------------------------------------------
// file_utils.c find_executable_path

<* file_utils.c `find_executable_path` (Linux: the directory of /proc/self/exe). *>
fn String find_executable_path()
{
	char[4096] buffer;
	sz len = libc::readlink("/proc/self/exe", &buffer, 4095);
	if (len < 0) @error_exit("Failed to resolve the executable path.");
	String exe = (String)buffer[:len];
	if (try slash = exe.rindex_of_char('/')) return str_copy(exe[:slash]);
	return str_copy(".");
}
