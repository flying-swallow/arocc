// #kind: run
// #exit: 31
/* Cover ordered float and double relations, equal signed zeros, infinities,
   and the unordered results produced by a quiet NaN. */
union FloatBits { float value; unsigned int bits; };

int main(void)
{
	volatile float fa = -2.0f;
	volatile float fb = 3.0f;
	volatile double da = -2.0;
	volatile double db = 3.0;
	int score = 0;

	if (fa < fb) score++;
	if (fa <= fb) score++;
	if (fb > fa) score++;
	if (fb >= fa) score++;
	if (fa == fa) score++;
	if (fa != fb) score++;
	if (da < db) score++;
	if (da <= db) score++;
	if (db > da) score++;
	if (db >= da) score++;
	if (da == da) score++;
	if (da != db) score++;

	union FloatBits nan_bits = { .bits = 0x7fc00000u };
	volatile float nan_value = nan_bits.value;
	volatile float one = 1.0f;
	if (!(nan_value == one)) score++;
	if (nan_value != one) score++;
	if (!(nan_value < one)) score++;
	if (!(nan_value <= one)) score++;
	if (!(nan_value > one)) score++;
	if (!(nan_value >= one)) score++;

	volatile float positive_zero = 0.0f;
	volatile float negative_zero = -0.0f;
	if (positive_zero == negative_zero) score++;
	if (!(positive_zero != negative_zero)) score++;
	if (positive_zero <= negative_zero) score++;
	if (positive_zero >= negative_zero) score++;

	union FloatBits infinity_bits = { .bits = 0x7f800000u };
	volatile float positive_infinity = infinity_bits.value;
	volatile float negative_infinity = -positive_infinity;
	if (positive_infinity > 3.0f) score++;
	if (negative_infinity < -3.0f) score++;

	volatile double double_zero = 0.0;
	volatile double double_nan = double_zero / double_zero;
	if (double_nan != double_nan) score++;
	if (!double_nan) score--; else score++;
	if (0.0) score--; else score++;
	if (da && db) score++;
	if (0.0 && db) score--; else score++;
	if (da || 0.0) score++;
	if (0.0 || db) score++;

	return score;
}
