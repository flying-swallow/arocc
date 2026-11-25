#!/bin/sh
ulimit -c 0
for arg in "$@"; do
 case "$arg" in
 */crash.c) kill -ABRT $$ ;;
 */timeout.c) sleep 10 ;;
 */error.c) echo "$arg:2:1: error: controlled diagnostic" >&2; exit 1 ;;
 */macro_note.c) echo "$arg:2:1: error: controlled diagnostic" >&2; echo "$arg:1:9: note: expanded from macro 'M'" >&2; echo "<scratch space>:1:1: note: expanded from here" >&2; exit 1 ;;
 esac
done
exit 0
