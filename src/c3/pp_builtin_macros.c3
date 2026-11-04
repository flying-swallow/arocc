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
// Calendar math is a direct port of Zig std.time.epoch (EpochSeconds,
// EpochDay.calculateYearDay, YearDay.calculateMonthDay): day count from
// 1970-01-01 walked year by year and month by month, proleptic Gregorian.
// String escaping reuses write_escaped (pp_print.c3, Zig fmtEscapes).
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::compilation, aro::diagnostics, aro::lang_opts;
import std::io, std::collections::list;

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
	if (self.environment.has_source_date_epoch)
	{
		ulong? parsed = parse_epoch_u64(self.environment.source_date_epoch);
		if (catch parsed) return INVALID_EPOCH~;
		if (parsed > compilation::MAX_SOURCE_EPOCH_TIMESTAMP) return INVALID_EPOCH~;
		return { .provided = true, .timestamp = parsed };
	}
	long? seconds = self.now_seconds();
	if (catch seconds) return INVALID_EPOCH~;
	if (seconds < 0) return INVALID_EPOCH~;
	ulong ts = (ulong)seconds;
	if (ts > compilation::MAX_SOURCE_EPOCH_TIMESTAMP) ts = compilation::MAX_SOURCE_EPOCH_TIMESTAMP;
	return { .provided = false, .timestamp = ts };
}

<*
 Zig std.fmt.parseInt(u64, s, 10) (std/fmt.zig parseIntWithGenericCharacter
 and parseIntWithSign): optional '+' or '-' sign; then at least one char,
 neither first nor last '_'; '_' anywhere else is skipped (doubled is fine);
 every other char must be a decimal digit. With '-', each digit while the
 accumulator is still 0 must be 0 (Zig negates the first non-zero digit,
 which overflows u64), so "-0" / "-000" / "-0_0" are 0 and "-1" fails.
 Overflow past ulong::max fails.
 @return? INVALID_EPOCH
*>
fn ulong? parse_epoch_u64(String text)
{
	if (text.len == 0) return INVALID_EPOCH~;
	bool neg = false;
	String digits = text;
	if (text[0] == '+' || text[0] == '-')
	{
		neg = text[0] == '-';
		digits = text[1..];
	}
	if (digits.len == 0) return INVALID_EPOCH~;
	if (digits[0] == '_' || digits[^1] == '_') return INVALID_EPOCH~;
	ulong acc = 0;
	foreach (c : digits)
	{
		if (c == '_') continue;
		if (c < '0' || c > '9') return INVALID_EPOCH~;
		ulong digit = (ulong)(c - '0');
		if (acc == 0 && neg)
		{
			if (digit != 0) return INVALID_EPOCH~;
			continue;
		}
		if (acc != 0)
		{
			if (acc > ulong::max / 10) return INVALID_EPOCH~;
			acc *= 10;
		}
		if (acc > ulong::max - digit) return INVALID_EPOCH~;
		acc += digit;
	}
	return acc;
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
	Compilation* comp = pp.comp;
	SourceEpoch? epoch = comp.source_epoch();
	if (catch f = epoch)
	{
		assert(f == INVALID_EPOCH);
		comp.diagnostics.add(DIAG_INVALID_SOURCE_EPOCH.message(DIAG_INVALID_SOURCE_EPOCH.fmt))!;
		return DEFAULT_SOURCE_EPOCH;
	}
	return epoch;
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
	CivilTime t = civil_time(timestamp);
	String month_name = MONTH_NAMES[t.month - 1];
	String text;
	switch (kind)
	{
		case DATE:
			text = string::tformat("\"%s %2d %d\"", month_name, t.day, t.year);
		case TIME:
			text = string::tformat("\"%02d:%02d:%02d\"", t.hour, t.minute, t.second);
		case TIMESTAMP:
			text = string::tformat("\"%s %s %2d %02d:%02d:%02d %d\"", DAY_NAMES[t.weekday], month_name, t.day, t.hour, t.minute, t.second, t.year);
	}
	self.gen_text(text);
}

const String[7] DAY_NAMES = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const String[12] MONTH_NAMES = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

<* A UTC calendar time (Zig std.time.epoch YearDay / MonthAndDay / DaySeconds). *>
struct CivilTime
{
	ulong year;
	<* 1..12 *>
	uint month;
	<* 1..31 (Zig day_index + 1) *>
	uint day;
	uint hour;
	uint minute;
	uint second;
	<* 0 = Mon .. 6 = Sun ((epoch_day + 3) % 7) *>
	uint weekday;
}

<* Zig std.time.epoch.isLeapYear. *>
fn bool is_leap_year(ulong year)
{
	if (year % 4 != 0) return false;
	if (year % 100 != 0) return true;
	return year % 400 == 0;
}

<* Zig std.time.epoch.getDaysInMonth (month 1..12). *>
fn uint days_in_month(bool leap, uint month)
{
	switch (month)
	{
		case 2: return leap ? 29 : 28;
		case 4:
		case 6:
		case 9:
		case 11: return 30;
		default: return 31;
	}
}

<* Zig EpochSeconds.getEpochDay/getDaySeconds + calculateYearDay + calculateMonthDay. *>
fn CivilTime civil_time(ulong timestamp)
{
	ulong day = timestamp / 86400;
	ulong secs = timestamp % 86400;
	CivilTime t = {
		.hour = (uint)(secs / 3600),
		.minute = (uint)(secs % 3600 / 60),
		.second = (uint)(secs % 60),
		.weekday = (uint)((day + 3) % 7),
	};
	ulong year = 1970;
	ulong day_of_year = day;
	while (true)
	{
		ulong year_size = is_leap_year(year) ? 366 : 365;
		if (day_of_year < year_size) break;
		day_of_year -= year_size;
		year++;
	}
	bool leap = is_leap_year(year);
	uint month = 1;
	while (true)
	{
		ulong month_size = days_in_month(leap, month);
		if (day_of_year < month_size) break;
		day_of_year -= month_size;
		month++;
	}
	t.year = year;
	t.month = month;
	t.day = (uint)day_of_year + 1;
	return t;
}

<* Append `bytes` escaped with Zig fmtEscapes (write_escaped) to comp.generated_buf. *>
fn void Preprocessor.gen_escaped(&self, String bytes)
{
	DString d;
	d.init(self.comp.gpa);
	defer d.free();
	if (catch write_escaped(&d, bytes)) unreachable("writing to a DString failed");
	self.gen_text(d.str_view());
}

<*
 Append raw text to comp.generated_buf, leaving a NUL in the spare capacity
 after it (as paste_tokens does): expanded_slice re-tokenizes generated
 tokens and requires the buffer to be NUL-terminated (Zig's tokenizer is
 bounds-checked instead).
*>
fn void Preprocessor.gen_text(&self, String text)
{
	List{char}* gen = &self.comp.generated_buf;
	gen.push_all((char[])text);
	gen.push(0);
	gen.size -= 1;
}

<*
 Zig std.fs.path.basename on POSIX (basenamePosix): the last '/'-separated
 component after trailing '/'s are dropped; "" for "" and "/".
*>
fn String path_basename(String path)
{
	sz end = path.len;
	while (end > 0 && path[end - 1] == '/') end--;
	if (end == 0) return "";
	sz start = end;
	while (start > 0 && path[start - 1] != '/') start--;
	return path[start..end - 1];
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
	Compilation* comp = pp.comp;
	switch (kind)
	{
		case FILE:
			sz start = comp.generated_buf.len();
			Source src = comp.get_source(pp.expansion_source_loc.id);
			bool replaced = false;
			foreach (r : pp.path_replacements)
			{
				if (src.path.starts_with(r.prefix))
				{
					pp.gen_text("\"");
					pp.gen_escaped(r.replacement);
					pp.gen_escaped(src.path[r.prefix.len..]);
					pp.gen_text("\"");
					replaced = true;
					break;
				}
			}
			if (!replaced)
			{
				pp.gen_text("\"");
				pp.gen_escaped(src.path);
				pp.gen_text("\"\n");
			}
			buf.push(pp.make_generated_token(start, STRING_LITERAL, tok));
		case BASE_FILE:
			pp.err_loc(pp.expansion_source_loc, DIAG_BASE_FILE_IS_CLANG_EXTENSION)!;
			sz start = comp.generated_buf.len();
			Source base = comp.get_source(pp.base_file);
			// Zig's loop has no `break`, so its `else` always runs: one replaced
			// literal per matching prefix, then always the unreplaced literal.
			foreach (r : pp.path_replacements)
			{
				if (base.path.starts_with(r.prefix))
				{
					pp.gen_text("\"");
					pp.gen_escaped(r.replacement);
					pp.gen_escaped(base.path[r.prefix.len..]);
					pp.gen_text("\"");
				}
			}
			pp.gen_text("\"");
			pp.gen_escaped(base.path);
			pp.gen_text("\"");
			buf.push(pp.make_generated_token(start, STRING_LITERAL, tok));
		case FILE_BASENAME:
			pp.err_loc(pp.expansion_source_loc, DIAG_FILE_NAME_IS_CLANG_EXTENSION)!;
			sz start = comp.generated_buf.len();
			Source src = comp.get_source(pp.expansion_source_loc.id);
			pp.gen_text("\"");
			pp.gen_escaped(path_basename(src.path));
			pp.gen_text("\"");
			buf.push(pp.make_generated_token(start, STRING_LITERAL, tok));
		case LINE:
			sz start = comp.generated_buf.len();
			pp.gen_text(string::tformat("%d\n", pp.expansion_source_loc.line));
			buf.push(pp.make_generated_token(start, PP_NUM, tok));
		case COUNTER:
			bool c2y = comp.langopts.standard.at_least(C2Y);
			pp.err(tok, c2y ? DIAG_PRE_C2Y_COUNTER : DIAG_C2Y_COUNTER)!;
			uint val = pp.counter;
			if (val > 0x7FFF_FFFF) pp.err(tok, DIAG_COUNTER_OVERFLOW)!;
			pp.counter += 1; // wraps (Zig +%=)
			sz start = comp.generated_buf.len();
			pp.gen_text(string::tformat("%d\n", val));
			buf.push(pp.make_generated_token(start, PP_NUM, tok));
		case DATE:
		case TIME:
			pp.err_loc(pp.expansion_source_loc, DIAG_DATE_TIME)!;
			sz start = comp.generated_buf.len();
			pp.write_date_time_stamp(kind == DATE ? DateTimeStampKind.DATE : DateTimeStampKind.TIME, pp.source_epoch.timestamp);
			buf.push(pp.make_generated_token(start, STRING_LITERAL, tok));
		case TIMESTAMP:
			pp.err_loc(pp.expansion_source_loc, DIAG_DATE_TIME)!;
			sz start = comp.generated_buf.len();
			ulong timestamp = pp.source_epoch.timestamp;
			if (!pp.source_epoch.provided) timestamp = pp.m_time(pp.expansion_source_loc.id)!;
			pp.write_date_time_stamp(TIMESTAMP, timestamp);
			buf.push(pp.make_generated_token(start, STRING_LITERAL, tok));
		case INCLUDE_LEVEL:
			pp.err_loc(pp.expansion_source_loc, DIAG_INCLUDE_LEVEL_IS_CLANG_EXTENSION)!;
			sz start = comp.generated_buf.len();
			pp.gen_text(string::tformat("%d\n", pp.include_depth));
			buf.push(pp.make_generated_token(start, PP_NUM, tok));
	}
}

