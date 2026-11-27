// #kind: run
// #exit: 14
int side_effect_count;

int main(void)
{
	int i = 0;
	while (i < 10) i += 3;

	int outer = 0;
	while (outer < 2)
	{
		int inner = 0;
		while (inner < 2) inner++;
		outer++;
	}

	int effect = 0;
	while (effect < 2)
	{
		side_effect_count++;
		effect++;
	}
	return i + side_effect_count;
}
