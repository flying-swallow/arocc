#!/bin/sh
ulimit -c 0
for arg in "$@"; do
 case "$arg" in
 */crash.c) kill -ABRT $$ ;;
 */timeout.c) sleep 10 ;;
 */error.c) echo "$arg:2:1: error: controlled diagnostic" >&2; exit 1 ;;
 esac
done
exit 0
