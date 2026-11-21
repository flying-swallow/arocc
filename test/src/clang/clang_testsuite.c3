module clang_testsuite;
import std::io, std::io::file, std::collections::list, std::collections::object, std::encoding::json, std::thread, std::time;
import aro_harness, gcc_testsuite;

fn Allocator heap() { $if env::TESTING: return tmem; $else return mem; $endif }

struct Expected { long line; String severity; }
struct Invocation { String path; String rel; String command; String text; }
struct Options { String root; String aro; String out; String filter; String suite; int jobs; double timeout; }
struct Context { Invocation[] cases; Options* opts; Object*[] results; Mutex lock; sz done; }

fn String subst(String s, String from, String to) => s.replace(heap(), from, to);
fn String strip(String s) => s.trim();
fn bool digits(String s) { if (!s.len) return false; foreach (c : s) if (c < '0' || c > '9') return false; return true; }

fn String[] logical_runs(String text)
{
 List{String} runs; runs.init(heap());
 String pending = "";
 foreach (line : aro_harness::split_lines(heap(), text))
 {
  sz? at = line.index_of("RUN:");
  if (catch at) continue;
  String cmd = strip(line[at + 4..]);
  pending = string::format(heap(), "%s%s", pending, cmd);
  if (pending.ends_with("\\")) { pending = string::format(heap(), "%s ", pending[..pending.len - 1]); continue; }
  runs.push(pending); pending = "";
 }
 if (pending.len) runs.push("UNFINISHED-RUN");
 return runs.array_view();
}

fn String translate(Invocation c, Options* opts, List{String}* cmd, List{String}* prefixes, bool* verify, bool* negative, List{String}* ignored)
{
 String run = c.command;
 foreach (String bad : { "|", ">", "<", ";", "&&", "`", "$(", "UNFINISHED-RUN" }) if (run.contains(bad)) return "shell or pipeline syntax";
 String[] words = gcc_testsuite::tcl_words(heap(), run);
 if (!words.len) return "empty RUN";
 sz i = 0;
 if (words[i] == "not") { *negative = true; i++; }
 if (i >= words.len || (words[i] != "%clang_cc1" && words[i] != "%clang")) return "unsupported RUN tool";
 bool cc1 = words[i] == "%clang_cc1";
 i++;
 cmd.push(opts.aro); cmd.push("-fno-color-diagnostics"); cmd.push("-fsyntax-only");
 if (cc1) cmd.push("-nostdinc");
 bool source = false;
 for (; i < words.len; i++)
 {
  String w = words[i];
  w = subst(subst(w, "%S", aro_harness::dirname_of(c.path)), "%s", c.path);
  if (w.contains("%")) return string::format(heap(), "unsupported substitution: %s", w);
  if (w.starts_with("-std=") && w.contains("++")) return "non-C standard";
  if (w == c.path) { source = true; cmd.push(w); continue; }
  if (w == "-verify" || w.starts_with("-verify="))
  {
   *verify = true;
   if (w == "-verify") { prefixes.push("expected"); }
   else { foreach (p : gcc_testsuite::split_char(heap(), w[8..], ',')) prefixes.push(p); }
   continue;
  }
  if (w.starts_with("-verify-ignore-unexpected="))
  { foreach (p : gcc_testsuite::split_char(heap(), w[26..], ',')) ignored.push(p); continue; }
  if (w == "-x" || w == "-triple" || w == "-target" || w == "-I" || w == "-isystem" || w == "-include" || w == "-D" || w == "-U")
  {
   if (++i >= words.len) return "missing flag operand";
   String arg = subst(subst(words[i], "%S", aro_harness::dirname_of(c.path)), "%s", c.path);
   if (arg.contains("%")) return "unsupported substitution";
   if (w == "-x" && arg != "c") return "non-C language";
   cmd.push(w == "-triple" ? "-target" : w); cmd.push(arg); continue;
  }
  if (w == "-fsyntax-only" || w == "-pedantic" || w == "-pedantic-errors" || w == "-nostdinc" || w == "-nobuiltininc" || w == "-ansi" || w.starts_with("-std=") || w.starts_with("-D") || w.starts_with("-U") || w.starts_with("-I") || w.starts_with("-W")) { cmd.push(w); continue; }
  return string::format(heap(), "unsupported flag: %s", w);
 }
 if (!source) return "RUN has no source input";
 cmd.push("--emulate=clang");
 return "";
}

fn String expectations(String text, String[] prefixes, List{Expected}* expected, bool* no_diags)
{
 long line_num = 0;
 foreach (line : aro_harness::split_lines(heap(), text))
 {
  line_num++;
  foreach (prefix : prefixes)
  {
   if (line.contains(string::format(heap(), "%s-no-diagnostics", prefix))) *no_diags = true;
   foreach (String sev : { "error", "warning", "note" })
   {
    String marker = string::format(heap(), "%s-%s", prefix, sev);
    String rest = line;
    while (true)
    {
     sz? found = rest.index_of(marker); if (catch found) break;
     rest = rest[found + marker.len..];
     long target = line_num;
     if (rest.starts_with("-re")) rest = rest[3..];
     if (rest.starts_with("@"))
     {
      sz end = 1; while (end < rest.len && rest[end] != ' ' && rest[end] != '\t' && rest[end] != '{') end++;
      String loc = rest[1:end - 1];
      if (loc.starts_with("+") || loc.starts_with("-")) { target += loc.to_long() ?? -1000000; }
      else { target = loc.to_long() ?? -1; }
      if (target < 1) return "unsupported diagnostic location";
      rest = rest[end..];
     }
     rest = strip(rest);
     int count = 1;
     if (!rest.starts_with("{{"))
     {
      sz? end = rest.index_of_char(' '); if (catch end) return "invalid diagnostic count";
      String n = rest[:end]; if (!digits(n)) return "unsupported diagnostic count";
      count = n.to_int() ?? -1; if (count < 1 || count > 10000) return "invalid diagnostic count";
      rest = strip(rest[end..]);
     }
     if (!rest.starts_with("{{")) return "invalid expected diagnostic";
     sz? close = rest.index_of("}}"); if (catch close) return "unterminated diagnostic annotation";
     for (int k = 0; k < count; k++) expected.push({ target, sev });
     rest = rest[close + 2..];
    }
   }
  }
 }
 if (*no_diags && expected.len()) return "conflicting no-diagnostics annotation";
 return "";
}

const bool HOST_LINUX @feat(LINUX) = true;
const bool HOST_LINUX @feat(!LINUX) = false;
const bool HOST_WINDOWS @feat(WIN32) = true;
const bool HOST_WINDOWS @feat(!WIN32) = false;
fn int feature(String name)
{
 switch (name.trim()) {
  case "system-linux": return HOST_LINUX ? 1 : 0;
  case "system-windows": return HOST_WINDOWS ? 1 : 0;
  case "x86-registered-target": return 1;
  default: return -1;
 }
}

fn Object* execute(Invocation c, Options* opts)
{
 Object* r = object::new_obj(heap());
 r.set("path", c.rel); r.set("run", gcc_testsuite::py_decode(heap(), c.command, true)); r.set("status", "UNSUPPORTED"); r.set("detail", "");
 foreach (line : aro_harness::split_lines(heap(), c.text))
 {
  if (line.contains("XFAIL:")) { r.set("detail", "XFAIL condition requires interpretation"); return r; }
  foreach (String directive : { "REQUIRES:", "UNSUPPORTED:" })
  {
   sz? pos = line.index_of(directive); if (catch pos) continue;
   foreach (cond : gcc_testsuite::split_char(heap(), line[pos + directive.len..], ','))
   {
    int value = feature(cond);
    if (value < 0) { r.set("detail", string::format(heap(), "unknown feature condition: %s", cond.trim())); return r; }
    if ((directive == "REQUIRES:" && !value) || (directive == "UNSUPPORTED:" && value))
    { r.set("status", "SKIP"); r.set("detail", cond.trim()); return r; }
   }
  }
 }
 List{String} cmd; cmd.init(heap()); List{String} prefixes; prefixes.init(heap()); List{String} ignored; ignored.init(heap());
 bool verify = false; bool negative = false; bool none = false;
 String reason = translate(c, opts, &cmd, &prefixes, &verify, &negative, &ignored);
 if (reason.len) { r.set("detail", reason); return r; }
 List{Expected} expected; expected.init(heap());
 if (verify && negative) { r.set("detail", "not applied to diagnostic verifier"); return r; }
 if (verify) reason = expectations(c.text, prefixes.array_view(), &expected, &none);
 if (reason.len) { r.set("detail", reason); return r; }
 r.set("cmd", string::tjoin(cmd.array_view(), " "));
 aro_harness::RunResult result = aro_harness::run(heap(), cmd.array_view(), { .cwd = aro_harness::dirname_of(c.path), .timeout_ms = (long)(opts.timeout * 1000.0) });
 String output = gcc_testsuite::py_decode(heap(), result.output(heap()), true);
 if (output.contains("unknown warning") || output.contains("unknown argument") || output.contains("unrecognized command-line")) { r.set("detail", "unsupported compiler option"); r.set("output", output); return r; }
 r.set("output", output); r.set("exit", result.returncode());
 if (!result.spawned || result.signal || result.timed_out || output.contains("panic:"))
 { r.set("status", result.timed_out ? "TIMEOUT" : "CRASH"); return r; }
 bool errors = negative;
 foreach (e : expected) if (e.severity == "error") errors = true;
 bool ok = errors ? result.exit_code != 0 : result.exit_code == 0;
 if (verify)
 {
  List{Expected} actual; actual.init(heap());
  foreach (line : aro_harness::split_lines(heap(), output))
  {
   String[] pieces = gcc_testsuite::split_char(heap(), line, ':');
   if (pieces.len < 5 || !digits(pieces[1]) || !digits(pieces[2])) continue;
   String sev = strip(pieces[3]); if (sev == "fatal error") sev = "error";
   if (sev != "error" && sev != "warning" && sev != "note") continue;
   if (pieces[0] != c.path && pieces[0] != aro_harness::basename_of(c.path)) { ok = false; continue; }
   actual.push({ pieces[1].to_long() ?? -1, sev });
  }
  foreach (got : actual)
  {
   bool matched = false;
   foreach (&want : expected) if (want.line == got.line && want.severity == got.severity) { want.line = -1; matched = true; break; }
   if (!matched)
   {
    bool ignore = false; foreach (x : ignored) if (x == got.severity) ignore = true;
    if (!ignore) ok = false;
   }
  }
  foreach (want : expected) if (want.line != -1) ok = false;
 }
 r.set("status", ok ? "PASS" : "FAIL"); r.set("detail", ok ? "" : "exit status or diagnostic severity/location/count mismatch"); return r;
}
fn void worker(void* ptr, sz i)
{
 Context* ctx = (Context*)ptr;
 Clock start = clock::now();
 Object* result = execute(ctx.cases[i], ctx.opts);
 ctx.results[i] = result;
 double seconds = (double)start.to_now() / 1e9;
 result.set("seconds", seconds);
 String detail = result.get_string("detail") ?? "";
 sz? newline = detail.index_of_char('\n');
 if (try newline) detail = detail[:newline];
 detail = detail.trim();
 if (detail.len > 160) detail = detail[:160];
 ctx.lock.lock();
 defer ctx.lock.unlock();
 sz done = ++ctx.done;
 io::printfn("[%5d/%d] %-11s clang:%s%s%s (%.2fs)", done, ctx.cases.len,
  result.get_string("status") ?? "", ctx.cases[i].rel,
  detail.len ? "  " : "", detail, seconds);
}

fn int main(String[] argv)
{
 Options opts = { .root = "test/clang", .aro = "bazel-bin/aro_c3", .out = "/tmp/aro-clang-testsuite", .filter = "*", .suite = "Lexer,Preprocessor,Parser,Sema,C", .jobs = 4, .timeout = 10 };
 foreach (i, arg : argv)
 {
  if (arg == "--help") { io::printn("clang_testsuite [--root PATH] [--aro PATH] [--suite Lexer,Preprocessor,Parser,Sema,C] [--filter GLOB] [--jobs N] [--timeout SECONDS] [--out PATH]"); return 0; }
  if (i == 0 || !arg.starts_with("--")) continue;
  if (i + 1 >= argv.len) return 2;
  String v = argv[i + 1];
  switch (arg) { case "--root": opts.root = v; case "--aro": opts.aro = v; case "--out": opts.out = v; case "--filter": opts.filter = v; case "--suite": opts.suite = v; case "--jobs": opts.jobs = v.to_int() ?? 1; case "--timeout": opts.timeout = (double)(v.to_int() ?? 10); default: return 2; }
 }
 if (opts.jobs < 1 || opts.timeout <= 0) return 2;
 String outputs = aro_harness::getenv(heap(), "TEST_UNDECLARED_OUTPUTS_DIR"); if (outputs.len) opts.out = outputs;
 opts.root = aro_harness::runfile(heap(), opts.root); opts.aro = aro_harness::runfile(heap(), opts.aro);
 List{Invocation} cases; cases.init(heap());
 foreach (suite : gcc_testsuite::split_char(heap(), opts.suite, ','))
 {
  if (suite != "Lexer" && suite != "Preprocessor" && suite != "Parser" && suite != "Sema" && suite != "C") { io::eprintfn("unknown suite: %s", suite); return 2; }
  String dir = string::format(heap(), "%s/%s", opts.root, suite);
  if (!aro_harness::dir_exists(dir)) { io::eprintfn("missing corpus directory: %s", dir); return 2; }
  String[] files = aro_harness::walk_files(heap(), dir) ?? {};
  foreach (name : files)
  {
   if (!name.ends_with(".c") || name.starts_with("Inputs/") || name.contains("/Inputs/") || !aro_harness::glob_match(opts.filter, aro_harness::basename_of(name))) continue;
   String path = string::format(heap(), "%s/%s", dir, name);
   String text = (String)(file::load(heap(), path) ?? {});
   String[] runs = logical_runs(text);
   if (!runs.len) { cases.push({ path, string::format(heap(), "%s/%s#0", suite, name), "NO-RUN", text }); }
   foreach (j, run : runs) cases.push({ path, string::format(heap(), "%s/%s#%d", suite, name, j + 1), run, text });
  }
 }
 int[2] shard = aro_harness::shard_info(); List{Invocation} selected; selected.init(heap());
 for (sz i = shard[0]; i < cases.len(); i += shard[1]) selected.push(cases[i]);
 Context ctx = { .cases = selected.array_view(), .opts = &opts }; ctx.results = alloc::new_array(heap(), Object*, ctx.cases.len);
 ctx.lock.init()!!;
 defer ctx.lock.destroy();
 aro_harness::parallel_for(opts.jobs, ctx.cases.len, &worker, &ctx);
 DString jsonl; jsonl.init(heap()); DString summary; summary.init(heap()); summary.append("# Clang compatibility results\n\n");
 int fails = 0;
 foreach (r : ctx.results) { jsonl.append(json::marshal(heap(), r)); jsonl.append_char('\n'); String status = r.get_string("status") ?? ""; if (status == "FAIL" || status == "CRASH" || status == "TIMEOUT") fails++; }
 foreach (String status : { "PASS", "FAIL", "CRASH", "TIMEOUT", "SKIP", "UNSUPPORTED" }) { int count = 0; foreach (r : ctx.results) if ((r.get_string("status") ?? "") == status) count++; summary.appendf("- %s: %d\n", status, count); }
 summary.append("\n## Failed commands\n\n");
 foreach (r : ctx.results)
 {
  String status = r.get_string("status") ?? "";
  if (status != "FAIL" && status != "CRASH" && status != "TIMEOUT") continue;
  summary.appendf("- %s clang:%s: %s\n", status, r.get_string("path") ?? "", r.get_string("detail") ?? "");
 }
 summary.append("\n## Unsupported command groups\n\n");
 List{String} reasons; reasons.init(heap());
 foreach (r : ctx.results)
 {
  if ((r.get_string("status") ?? "") != "UNSUPPORTED") continue;
  String reason = r.get_string("detail") ?? "";
  bool seen = false; foreach (x : reasons) if (x == reason) seen = true;
  if (seen) continue;
  reasons.push(reason); int count = 0;
  foreach (other : ctx.results) if ((other.get_string("status") ?? "") == "UNSUPPORTED" && (other.get_string("detail") ?? "") == reason) count++;
  summary.appendf("- %d: %s (e.g. clang:%s)\n", count, reason, r.get_string("path") ?? "");
 }
 aro_harness::mkdir_p(opts.out)!!;
 file::save(string::format(heap(), "%s/results.jsonl", opts.out), (char[])jsonl.str_view())!!;
 file::save(string::format(heap(), "%s/summary.md", opts.out), (char[])summary.str_view())!!;
 io::printfn("%d commands: %d failed\nresults: %s/results.jsonl\nsummary: %s/summary.md", ctx.cases.len, fails, opts.out, opts.out); return fails ? 1 : 0;
}
