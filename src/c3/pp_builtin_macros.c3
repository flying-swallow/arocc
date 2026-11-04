// Builtin object macros and the source epoch, from src/aro/Preprocessor.zig
// (expandObjMacro's `.macro_builtin_obj` arm, writeDateTimeStamp, init's
// source-epoch fallback) and Compilation.zig (Environment.sourceEpoch).
// OWNER: plan 14.4 `dynamic-macros`.
//
// Provider wiring: BUILTINS below is the plan-14 BuiltinProvider. Its
// expand_func hook (builtin_expand_func) lives in pp_feature_queries.c3
// (14.5). The stage-2 integrator makes BUILTINS the default of
// Preprocessor.init (preprocessor.c3); until then callers pass it explicitly.
//
// Determinism: nothing here reads the host clock or environment directly.
// The epoch comes from comp.environment.source_date_epoch (SOURCE_DATE_EPOCH,
// borrowed text) or comp.clock (compilation::SYSTEM_CLOCK by default; tests
// and the probe use compilation::fixed_clock). __TIMESTAMP__ with a `system`
// epoch uses Preprocessor.m_time (FileProvider.source_mtime, plan 15).
//
// Stage 0: signatures only; every body is a stub.
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::compilation, aro::diagnostics;

<* Zig `error.InvalidEpoch` from Environment.sourceEpoch. *>
excuse INVALID_EPOCH;

<* The plan-14 builtin macro provider (source epoch, builtin object and function macros). *>
const BuiltinProvider BUILTINS = { null, &builtin_source_epoch, &builtin_expand_obj, &builtin_expand_func };

<*
 Zig `Environment.sourceEpoch(io)`. With environment.has_source_date_epoch:
 parse it with Zig std.fmt.parseInt(u64, s, 10) (from Zig std knowledge,
 unverified: optional leading '+'; '_' separators allowed between digits
 but not first/last/doubled; '-' or any other non-digit, empty input and
 u64 overflow fail); a failure or a value > MAX_SOURCE_EPOCH_TIMESTAMP is
 INVALID_EPOCH, else `provided`. Otherwise read comp.now_seconds(): a
 fault or a negative value is INVALID_EPOCH, else `system` clamped to
 [0, MAX_SOURCE_EPOCH_TIMESTAMP].
 @return? INVALID_EPOCH
*>
fn SourceEpoch? Compilation.source_epoch(&self)
{
	unreachable("stage 0 stub");
}

<*
 BuiltinProvider.source_epoch: Zig Preprocessor.init's
 `options.source_epoch orelse (comp.environment.sourceEpoch(io) catch ...)`.
 On INVALID_EPOCH add DIAG_INVALID_SOURCE_EPOCH's text/kind/opt with no
 location directly to comp.diagnostics (FATAL_ERROR propagates) and return
 DEFAULT_SOURCE_EPOCH (`provided` 0).
 @return? compilation::FATAL_ERROR
*>
fn SourceEpoch? builtin_source_epoch(void* ctx, Preprocessor* pp)
{
	unreachable("stage 0 stub");
}

<* Zig `DateTimeStampKind`. *>
enum DateTimeStampKind : char
{
	DATE,
	TIME,
	TIMESTAMP,
}

<*
 Zig `writeDateTimeStamp`: append to comp.generated_buf (UTC, proleptic
 Gregorian from std.time.epoch):
 DATE      "\"Mmm dd yyyy\"" with the day right-aligned to width 2 (space pad);
 TIME      "\"hh:mm:ss\"" zero padded;
 TIMESTAMP "\"Ddd Mmm dd hh:mm:ss yyyy\"" (weekday (epoch_day + 3) % 7 over
           Mon..Sun, day space-padded to 2).
 No trailing newline (unlike FILE/LINE).
*>
fn void Preprocessor.write_date_time_stamp(&self, DateTimeStampKind kind, ulong timestamp)
{
	unreachable("stage 0 stub");
}

<*
 BuiltinProvider.expand_obj: Zig expandObjMacro's `.macro_builtin_obj` arm.
 Each kind appends exactly one token to `buf` made with
 pp.make_generated_token(start, id, tok) after writing its text at
 start = comp.generated_buf.len():
 FILE           STRING_LITERAL: the source path of expansion_source_loc.id;
                the first path_replacements entry whose prefix matches gives
                "\"<escaped replacement><escaped rest>\"" (no newline, stop);
                otherwise "\"<escaped path>\"\n". Escaping is Zig
                std.zig.fmtEscapes.
 BASE_FILE      DIAG_BASE_FILE_IS_CLANG_EXTENSION at expansion_source_loc;
                like FILE for pp.base_file but Zig never breaks out of the
                replacement loop, so it writes one replaced literal per
                matching prefix and then ALWAYS the unreplaced
                "\"<escaped path>\"" too (no newline) -- preserve this.
 FILE_BASENAME  DIAG_FILE_NAME_IS_CLANG_EXTENSION; "\"<escaped basename>\""
                (std.fs.path.basename).
 LINE           PP_NUM "<expansion_source_loc.line>\n".
 COUNTER        DIAG_PRE_C2Y_COUNTER (standard >= C2Y) else DIAG_C2Y_COUNTER
                at `tok`; DIAG_COUNTER_OVERFLOW at `tok` if counter >
                0x7FFF_FFFF; PP_NUM "<counter>\n" with the old value, counter
                wraps (+%= 1).
 DATE, TIME     DIAG_DATE_TIME at expansion_source_loc; STRING_LITERAL from
                write_date_time_stamp(source_epoch.timestamp).
 TIMESTAMP      DIAG_DATE_TIME; timestamp = provided epoch, or for `system`
                pp.m_time(expansion_source_loc.id) (aro::UNSUPPORTED until
                plan 15 propagates).
 INCLUDE_LEVEL  DIAG_INCLUDE_LEVEL_IS_CLANG_EXTENSION; PP_NUM "<include_depth>\n".
 Diagnostics "at expansion_source_loc" use pp.err_loc.
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn void? builtin_expand_obj(void* ctx, Preprocessor* pp, BuiltinObject kind, TokenWithExpansionLocs tok, ExpandBuf* buf)
{
	unreachable("stage 0 stub");
}
