// Execute every frozen record mapping against aro_cc. The two expected
// failure classifications are derived from aro_cc/test/record_runner.zig; the pinned
// Zig run reported aggregate counts but did not print those individual classes.
module record_regression;
import std::io, std::os::env, std::io::file, std::core::string, aro_record_runner;

const String ARO = env::WIN32 ? "aro_cc/aro_cc.exe" : "aro_cc/aro_cc";

fn String aro_binary()
{
	String root = env::get_var(tmem, "TEST_SRCDIR") ?? "";
	String workspace = env::get_var(tmem, "TEST_WORKSPACE") ?? "_main";
	assert(root.len, "TEST_SRCDIR is required to resolve aro_cc from runfiles");
	String candidate = string::format(tmem, "%s/%s/%s", root, workspace, ARO);
	assert(file::is_file(candidate), "aro_cc binary missing from runfiles: %s", candidate);
	return candidate;
}
const String RECORDS = "aro_cc/test/records";

fn void complete_record_fixture_regression() @test
{
	String aro = aro_binary();
	RecordReport report = aro_record_runner::run_suite(tmem, RECORDS, aro, io::stdout());
	assert(report.selected == 9353, "record tuple count differs from frozen baseline");
	assert(report.executed == 9009, "record invocation count differs from frozen baseline");
	assert(report.passed == 9007, "record passing count differs from frozen reference run");
	assert(report.expected_failures == 2, "source-derived expected failure count differs");
	assert(report.skipped == 2, "record expected-failure skip count differs from frozen reference run");
	assert(report.invalid_targets == 344, "record invalid-target count differs from frozen baseline");
	assert(report.excluded == 0, "record global exclusion count differs from frozen source");
	assert(report.crashes == 0, "arocc crashed on a record fixture");
	assert(report.unexpected_passes == 0, "a source-derived expected failure passed unexpectedly");
	assert(report.failures == 0, "record fixture diagnostics differ from expected classifications");
}
