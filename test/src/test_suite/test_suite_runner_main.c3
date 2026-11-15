// Command-line entry point of the test suite runner (see test_suite_runner.c3).
module test_suite_runner_main;
import test_suite_runner;

fn int main(String[] args) => test_suite_runner::run_main(args);
