// Execute every frozen record mapping against aro_c3. The two expected
// failure classifications are derived from test/record_runner.zig; the pinned
// Zig run reported aggregate counts but did not print those individual classes.
module record_regression;
import std::io, std::os::env, aro_record_runner;

const String ARO = env::WIN32 ? "aro_c3.exe" : "aro_c3";
const String RECORDS = "test/records";

fn void complete_record_fixture_regression() @test
{
	assert(file::is_file(ARO), "aro_c3 binary missing from runfiles");
	RecordReport report = aro_record_runner::run_suite(tmem, RECORDS, ARO, io::stdout());
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
