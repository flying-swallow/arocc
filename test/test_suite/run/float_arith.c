// #kind: run
// #exit: 19
/* Exercise runtime float and double arithmetic, compound assignments, mixed
   precision, and the sign of a zero result. */
union FloatBits { float value; unsigned int bits; };

int main(void)
{
	volatile float f = 5.5f;
	volatile float g = 2.0f;
	volatile double d = 9.0;
	volatile double e = 4.0;
	int score = 0;

	float f_add = f + g;
	float f_sub = f - g;
	float f_mul = f * g;
	float f_div = f / g;
	float f_neg = -f;
	double d_add = d + e;
	double d_sub = d - e;
	double d_mul = d * e;
	double d_div = d / e;
	double mixed = f + d;

	if (f_add == 7.5f) score++;
	if (f_sub == 3.5f) score++;
	if (f_mul == 11.0f) score++;
	if (f_div == 2.75f) score++;
	if (f_neg == -5.5f) score++;
	if (d_add == 13.0) score++;
	if (d_sub == 5.0) score++;
	if (d_mul == 36.0) score++;
	if (d_div == 2.25) score++;
	if (mixed == 14.5) score++;

	f += g;
	if (f == 7.5f) score++;
	f -= g;
	if (f == 5.5f) score++;
	f *= g;
	if (f == 11.0f) score++;
	f /= g;
	if (f == 5.5f) score++;
	d++;
	if (d == 10.0) score++;
	d--;
	if (d == 9.0) score++;

	volatile float negative_zero = -0.0f;
	float zero_product = negative_zero * 1.0f;
	union FloatBits zero_bits = { .value = zero_product };
	if (zero_product == 0.0f) score++;
	if (zero_bits.bits == 0x80000000u) score++;
	if (1.0 / -0.0 < 0) score++;

	return score;
}
