// #kind: run
// #exit: 0
// #opt: -O0
// GNU labels as values: `&&label` in local and static tables, `goto *expr`,
// and PHIs in blocks only reached through computed gotos.
#include <stdio.h>
static int run(const unsigned char *code)
{
	void *table[] = { &&op_inc, &&op_dbl, &&op_halt };
	int acc = 0;
	goto *table[*code++];
op_inc: acc += 1; goto *table[*code++];
op_dbl: acc *= 2; goto *table[*code++];
op_halt: return acc;
}
static int run_static(const unsigned char *code)
{
	static void *const table[] = { &&op_inc, &&op_dbl, &&op_halt };
	int acc = 0, n = 0;
	goto *table[*code++];
op_inc: acc += 1; n++; goto *table[*code++];
op_dbl: acc *= 2; n++; goto *table[*code++];
op_halt: return acc * 100 + n;
}
int main(void)
{
	unsigned char prog[] = { 0, 0, 1, 0, 1, 2 };
	void *p = &&end;
	if (run(prog) != 10 || run_static(prog) != 1005) return 1;
	goto *p;
	return 2;
end:
	return &&end != &&end ? 3 : 0;
}
