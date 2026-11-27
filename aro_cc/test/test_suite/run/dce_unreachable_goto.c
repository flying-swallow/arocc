// #kind: run
// #exit: 0

static int choose_path(int use_goto)
{
	if (use_goto) goto reachable;
	return 0;
	for (;;) {
		return 2;
	}
reachable:
	return 1;
}

int main(void)
{
	if (choose_path(0) != 0) return 1;
	if (choose_path(1) != 1) return 2;
	return 0;
}
