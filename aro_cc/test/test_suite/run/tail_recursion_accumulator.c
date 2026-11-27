// #kind: run
// #exit: 0
// `return f(...) op x` (op + or *) becomes a loop with an accumulator: the
// results, including unsigned wrap-around and every side effect, must not change.
#include <stdio.h>

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
static unsigned fact(unsigned n) { return n <= 1 ? 1 : n * fact(n - 1); }
static long sum_to(long n) { if (n == 0) return 0; return n + sum_to(n - 1); }
static unsigned wrap_mul(unsigned n) { return n == 0 ? 3u : wrap_mul(n - 1) * 1000003u; }

static int trace[16];
static int trace_len;
static int note(int v) { trace[trace_len++] = v; return v; }
/* `note(n) + ordered(n - 1)` leaves the call order unspecified; only the sum and
   the number of calls are checked. */
static int ordered(int n) { if (n == 0) return note(100); return note(n) + ordered(n - 1); }

static int mixed(int n, int acc)
{
	if (n <= 0) return acc;
	if (n & 1) return mixed(n - 1, acc + 1);   /* plain tail call */
	return 2 + mixed(n - 1, acc);              /* accumulating */
}

int main(void)
{
	int fails = 0;
#define CHECK(e, want) do { if ((e) != (want)) { printf("line %d: %ld\n", __LINE__, (long)(e)); fails++; } } while (0)
	CHECK(fib(0), 0);
	CHECK(fib(1), 1);
	CHECK(fib(20), 6765);
	CHECK(fact(0), 1u);
	CHECK(fact(10), 3628800u);
	CHECK(fact(20), 2192834560u); /* wraps modulo 2^32 */
	CHECK(sum_to(1000), 500500);
	CHECK(wrap_mul(5), 3u * 1000003u * 1000003u * 1000003u * 1000003u * 1000003u);
	CHECK(ordered(3), 106);
	CHECK(trace_len, 4);
	CHECK(trace[0] + trace[1] + trace[2] + trace[3], 106);
	CHECK(mixed(6, 0), 3 + 6);
	return fails;
}
