#!/bin/sh
# Fake compiler used by //test/migration:runner_tests. It ignores its
# arguments and behaves as directed by environment variables, which the test
# cases set through their manifest `env = ...` line (or the test process):
#   FAKE_ARGV=<file>    write "cwd=<pwd>" and one "arg=<arg>" line per argument
#   FAKE_OUT=<file>     copy <file> to stdout
#   FAKE_ERR=<file>     copy <file> to stderr
#   FAKE_FLOOD=<n>      write about <n> bytes to stdout and to stderr, interleaved
#   FAKE_ECHO=<text>    print "fake.c:1:1: warning: <text>" to stderr
#   FAKE_SIGNAL=<sig>   kill itself with <sig> after producing output
#   FAKE_EXIT=<n>       exit status (default 0)
# Relative file names resolve against the case directory (the child's CWD).
if [ -n "$FAKE_ARGV" ]; then
    {
        printf 'cwd=%s\n' "$(pwd)"
        for a in "$@"; do printf 'arg=%s\n' "$a"; done
    } > "$FAKE_ARGV"
fi
if [ -n "$FAKE_FLOOD" ]; then
    i=0
    line=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    while [ "$i" -lt "$FAKE_FLOOD" ]; do
        printf '%s\n' "$line"
        printf '%s\n' "$line" >&2
        i=$((i + 64))
    done
fi
if [ -n "$FAKE_OUT" ]; then cat "$FAKE_OUT"; fi
if [ -n "$FAKE_ERR" ]; then cat "$FAKE_ERR" >&2; fi
if [ -n "$FAKE_ECHO" ]; then printf 'fake.c:1:1: warning: %s\n' "$FAKE_ECHO" >&2; fi
if [ -n "$FAKE_SIGNAL" ]; then kill -s "$FAKE_SIGNAL" $$; fi
exit "${FAKE_EXIT:-0}"
