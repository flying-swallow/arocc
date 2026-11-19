// #kind: run
// #exit: 42
// gcc.c-torture/compile/limits-caselabels.c reduced: chained `case A: case B: ...`
// labels are parsed and lowered in a loop (no stack frame per label), duplicate
// checks are hashed, and register liveness only tracks cross-block values.
// 20000 labels; repetition is additive (never nested macro calls).
#define C10 case __COUNTER__: case __COUNTER__: case __COUNTER__: case __COUNTER__: case __COUNTER__: \
	case __COUNTER__: case __COUNTER__: case __COUNTER__: case __COUNTER__: case __COUNTER__:
#define C100 C10 C10 C10 C10 C10 C10 C10 C10 C10 C10
#define C1000 C100 C100 C100 C100 C100 C100 C100 C100 C100 C100
#define C10000 C1000 C1000 C1000 C1000 C1000 C1000 C1000 C1000 C1000 C1000

int classify(long i)
{
	switch (i)
	{
		C10000 C10000
			return 1;
		default:
			return 0;
	}
}

int main(void)
{
	// 0 and 19999 are labels; 20000 and -1 are not.
	return classify(0) + classify(19999) * 2 + classify(20000) * 4 + classify(-1) * 8 + 39;
}
