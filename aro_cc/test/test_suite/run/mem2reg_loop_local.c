// #kind: run
// #exit: 0

static int sum_loop_local(int n)
{
	int sum = 0;
	for (int i = 0; i < n; i++) {
		int t;
		if (i & 1) t = i;
		else t = -i;
		sum += t;
	}
	return sum;
}

int main(void)
{
	if (sum_loop_local(0) != 0) return 1;
	if (sum_loop_local(1) != 0) return 2;
	if (sum_loop_local(2) != 1) return 3;
	if (sum_loop_local(10) != 5) return 4;
	if (sum_loop_local(11) != -5) return 5;
	return 0;
}
