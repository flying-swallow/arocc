// #kind: run
// #exit: 0
#include <setjmp.h>

static void jump_back(jmp_buf environment)
{
	longjmp(environment, 9);
}

/* Keep the setjmp frame alive as a real callee while jump_back longjmps. */
static int run_jump(jmp_buf environment)
{
	if (setjmp(environment) == 9) return 9;
	jump_back(environment);
	return -1;
}

int main(void)
{
	jmp_buf environment;
	return run_jump(environment) == 9 ? 0 : 1;
}
