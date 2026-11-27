#!/usr/bin/env python3
"""Focused checks for c3c fixture parsing and diagnostic matching."""

import pathlib
import tempfile
import unittest

import runner


class RunnerTests(unittest.TestCase):
    def fixture(self, suffix: str, content: str):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = pathlib.Path(temp.name) / ("sample" + suffix)
        path.write_text(content, encoding="utf-8")
        return runner.parse_case(path)

    def test_positive_single_file(self):
        case = self.fixture(".c3", "module sample;\nfn void main() {}\n")
        self.assertEqual(case.sources, {"sample.c3": ["module sample;\n", "fn void main() {}\n"]})
        self.assertEqual(runner.check_diagnostics(case, "", 0), [])

    def test_expected_error_and_warning(self):
        case = self.fixture(".c3", "// #error: bad module\nmodule if;\nfn void x() {} // #warning: unused\n")
        self.assertEqual(case.expected, [
            runner.Expected("sample.c3", 1, "Error", "bad module"),
            runner.Expected("sample.c3", 2, "Warning", "unused"),
        ])
        output = "(/tmp/sample.c3:1:8) Error: bad module name\n(/tmp/sample.c3:2:1) Warning: unused function\n"
        self.assertEqual(runner.check_diagnostics(case, output, 1), [])

    def test_multifile_and_target(self):
        case = self.fixture(".c3t", "// #target: macos-x64\nmodule first;\n// #file: second.c3\nmodule second; // #error: failure\n")
        self.assertEqual(case.target, "macos-x64")
        self.assertEqual(list(case.sources), ["sample.c3", "second.c3"])
        self.assertEqual(case.expected, [runner.Expected("second.c3", 1, "Error", "failure")])

    def test_unsupported_and_skip(self):
        case = self.fixture(".c3t", "// #opt: -O2\n/* #expect: test.ll\nanything\n")
        self.assertEqual(len(case.unsupported), 2)
        self.assertEqual(case.sources["sample.c3"], [])
        skipped = self.fixture(".c3", "// #skip\nmodule sample;\n")
        self.assertTrue(skipped.skipped)

    def test_unexpected_diagnostic_fails(self):
        case = self.fixture(".c3", "module sample;\n")
        self.assertTrue(runner.check_diagnostics(case, "(/tmp/sample.c3:1:1) Error: bad\n", 1))

    def test_note_does_not_change_expected_diagnostics(self):
        case = self.fixture(".c3", "// #error: bad\nmodule sample;\n")
        output = "(/tmp/sample.c3:1:1) Error: bad\n(/tmp/sample.c3:1:1) Note: detail\n"
        self.assertEqual(runner.check_diagnostics(case, output, 1), [])


if __name__ == "__main__":
    unittest.main()
