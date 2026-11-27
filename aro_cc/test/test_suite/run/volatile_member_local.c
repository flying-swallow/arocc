// #kind: run
// #exit: 0

struct S { volatile int v; };

int main(void)
{
	struct S s;
	s.v = 7;
	return s.v == 7 ? 0 : 1;
}
