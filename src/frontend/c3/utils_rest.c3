// The c3c src/utils helpers sema calls that are not ported elsewhere:
// file_utils.c (stubs), time.c (stubs), compiler_tests/benchmark.c,
// stringutils.c / lib.h `StringSlice` helpers and lib.h `a5hash`.
//
// Deviations from c3c:
// - `StringSlice { ptr, len }` is a C3 String.
// - `BenchTime` is a std::time Clock.
// - `char **out` parameters are `String*`.
module aro::frontend::c3::compiler;
import std::time::clock;

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

// lib.h:320
fn ulong a5hash(String key, uint len, ulong seed)
{
	unreachable("sema stub: a5hash");
}

// ---------------------------------------------------------------------------
// file_utils.c

// file_utils.c:194
fn bool dir_change(String path)
{
	unreachable("sema stub: dir_change");
}

// file_utils.c:243
fn bool file_namesplit(String path, String* filename_ptr, String* directory_ptr)
{
	unreachable("sema stub: file_namesplit");
}

// file_utils.c:419
fn char* file_read_binary(String path, usz* size)
{
	unreachable("sema stub: file_read_binary");
}

// file_utils.c:659
fn bool file_path_is_relative(String file_name)
{
	unreachable("sema stub: file_path_is_relative");
}

// file_utils.c:702
fn String file_append_path(String path, String name)
{
	unreachable("sema stub: file_append_path");
}

// file_utils.c:947
fn String execute_cmd(String cmd, bool ignore_failure, String stdin_string, usz limit)
{
	unreachable("sema stub: execute_cmd");
}

// file_utils.c (file_add_wildcard_files): only reached when a stdlib dir is set.
fn void file_add_wildcard_files(String[]* files, String path, bool recursive, String[] suffix_list, int suffix_count)
{
	unreachable("sema stub: file_add_wildcard_files");
}

// ---------------------------------------------------------------------------
// time.c

// time.c:7
fn String time_get()
{
	unreachable("sema stub: time_get");
}

// time.c:18
fn String date_get()
{
	unreachable("sema stub: date_get");
}
