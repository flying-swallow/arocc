// #kind: run
// #exit: 0
/* Exercise scalar float and double moves through locals, a global table,
   pointers, a conditional expression, and a loop-carried double value. */
static double table[] = { 1.5, -2.25, 3.75 };

union FloatBits { float value; unsigned int bits; };
union DoubleBits { double value; unsigned long bits; };

int main(int argc, char **argv)
{
	(void)argv;
	float f = 1.0f;
	float *fp = &f;
	*fp = 2.5f;

	double d = 0.5;
	double *dp = &d;
	double *table_ptr = &table[1];
	*table_ptr = table[2];
	*dp = *table_ptr;

	int choose_local = argc == 1;
	double selected = choose_local ? *dp : table[0];
	double carried = selected;
	int rounds = argc + 2;
	for (int i = 0; i < rounds; ++i)
	{
		if (i == argc) carried = table[2];
	}

	union FloatBits f_bits = { .value = f };
	union DoubleBits d_bits = { .value = d };
	union DoubleBits selected_bits = { .value = selected };
	union DoubleBits carried_bits = { .value = carried };
	int failures = 0;
	if (f_bits.bits != 0x40200000u) failures |= 1;
	if (d_bits.bits != 0x400e000000000000ul) failures |= 2;
	if (selected_bits.bits != 0x400e000000000000ul) failures |= 4;
	if (carried_bits.bits != 0x400e000000000000ul) failures |= 8;
	return failures;
}
