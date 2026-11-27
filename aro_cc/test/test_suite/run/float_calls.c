// #kind: run
// #exit: 0
/* Exercise mixed integer/SSE arguments, stack-passed doubles, scalar returns,
   indirect calls, and recursive calls that carry a double argument. */

double mixed(int a, double b, int c, double d)
{
	return a + b + c + d;
}

double sum_ten_doubles(
	double a, double b, double c, double d, double e,
	double f, double g, double h, double i, double j)
{
	return a + b + c + d + e + f + g + h + i + j;
}

float scale_float(float value)
{
	return value * 2.0f;
}

double scale_double(double value)
{
	return value * 2.0;
}

double recurse_double(unsigned int depth, double value)
{
	if (depth == 0) return value;
	return recurse_double(depth - 1, value + 0.75);
}

int main(void)
{
	int failures = 0;
	if (mixed(2, 3.5, 4, -1.25) != 8.25) failures++;
	if (sum_ten_doubles(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) != 55.0) failures++;
	if (scale_float(1.25f) != 2.5f) failures++;
	if (scale_double(-2.25) != -4.5) failures++;

	double (* volatile indirect)(int, double, int, double) = mixed;
	if (indirect(1, 2.5, 3, 4.5) != 11.0) failures++;
	if (recurse_double(4, 1.5) != 4.5) failures++;
	return failures;
}
