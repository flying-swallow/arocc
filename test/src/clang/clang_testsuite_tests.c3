module clang_suite_tests;
import std::io, clang_testsuite, aro_harness, std::collections::list;
fn void logical_commands() @test
{
 String[] runs = clang_testsuite::logical_runs("// RUN: %clang_cc1 \\\n// RUN: %s -verify\n// RUN: tool\n");
 assert(runs.len == 2); assert(runs[0].contains("%s -verify"));
}
fn void diagnostic_annotations() @test
{
 List{Expected} want; want.init(tmem); bool none = false;
 String[1] prefixes = { "c99" };
 String reason = clang_testsuite::expectations("int x; // c99-error@+1 2 {{message}}\nint y; // c99-note@1 {{note}}", prefixes[..], &want, &none);
 assert(!reason.len && want.len() == 3 && want[0].line == 2 && want[2].line == 1);
}
fn void comment_anchored_annotations() @test
{
 List{Expected} want; want.init(tmem); bool none = false; String[1] prefixes = { "expected" };
 // A backslash-continued line comment and a multi-line block comment anchor at their first line.
 String text = "int a; // expected-warning {{x}} \\\n// expected-warning {{y}}\nint b; /* expected-note {{z}}\n expected-error@+1 {{w}} */\nint c;";
 assert(!clang_testsuite::expectations(text, prefixes[..], &want, &none).len);
 assert(want.len() == 4 && want[0].line == 1 && want[1].line == 1 && want[2].line == 3 && want[3].line == 4);
}
fn void unsupported_annotation() @test
{
 List{Expected} want; want.init(tmem); bool none = false; String[1] prefixes = { "expected" };
 assert(clang_testsuite::expectations("// expected-error@* {{bad}}", prefixes[..], &want, &none).len > 0);
}
fn void controlled_outcomes() @test
{
 Options opts = { .aro = aro_harness::runfile(tmem, "test/src/clang/data/fake_aro.sh"), .timeout = 0.05 };
 String dir = aro_harness::dirname_of(opts.aro);
 String[5] names = { "pass", "mismatch", "error", "crash", "timeout" };
 String[5] statuses = { "PASS", "FAIL", "PASS", "CRASH", "TIMEOUT" };
 foreach (i, name : names)
 {
  opts.timeout = name == "timeout" ? 0.05 : 2.0;
  String path = string::format(tmem, "%s/%s.c", dir, name);
  Invocation c = { .path = path, .rel = name, .command = "%clang_cc1 %s -verify", .text = name == "pass" ? "int x; // expected-no-diagnostics" : "int x;\n// expected-error {{ignored wording}}" };
  String got = clang_testsuite::execute(c, &opts).get_string("status") ?? "";
  if (got != statuses[i]) io::printfn("%s got %s expected %s", name, got, statuses[i]);
  assert(got == statuses[i]);
 }
 String error_path = string::format(tmem, "%s/error.c", dir);
 Invocation excluded = { .path = error_path, .rel = "exclusion", .command = "%clang_cc1 %s -verify -verify-ignore-unexpected=error", .text = "int x;\n// expected-error {{still required}}" };
 assert((clang_testsuite::execute(excluded, &opts).get_string("status") ?? "") == "PASS");
 // Macro-backtrace notes, in this or another file, are not -verify diagnostics.
 Invocation macro_note = { .path = string::format(tmem, "%s/macro_note.c", dir), .rel = "macro_note", .command = "%clang_cc1 %s -verify", .text = "#define M 1\n// expected-error {{controlled}}" };
 assert((clang_testsuite::execute(macro_note, &opts).get_string("status") ?? "") == "PASS");
 Invocation pipeline = { .command = "%clang_cc1 %s | FileCheck %s" };
 assert((clang_testsuite::execute(pipeline, &opts).get_string("status") ?? "") == "UNSUPPORTED");
}
fn void command_translation_and_conditions() @test
{
 Options opts = { .aro = "aro" };
 Invocation c = { .path = "/s/file.c", .command = "not %clang_cc1 -triple x86_64-pc-linux-gnu -DTEST -verify=c99,common -fsyntax-only %s" };
 List{String} cmd; cmd.init(tmem); List{String} prefixes; prefixes.init(tmem); List{String} ignored; ignored.init(tmem);
 bool verify = false; bool negative = false;
 assert(!clang_testsuite::translate(c, &opts, &cmd, &prefixes, &verify, &negative, &ignored).len);
 assert(verify && negative && prefixes.len() == 2 && cmd[cmd.len() - 1] == "--emulate=clang");
 c.text = "// UNSUPPORTED: x86-registered-target";
 assert((clang_testsuite::execute(c, &opts).get_string("status") ?? "") == "SKIP");
 c.text = "// REQUIRES: unknown-feature";
 assert((clang_testsuite::execute(c, &opts).get_string("status") ?? "") == "UNSUPPORTED");
}
