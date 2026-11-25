// #kind: run
// #exit: 0
// -0.0 in a local aggregate initializer is stored, not skipped as "already
// zero" (gcc ieee pr72824-2.c).
typedef float V __attribute__((vector_size(16)));
int main(void)
{
	float a[3] = { -0.0f, 1, -0.0f };
	struct { double x; } s = { -0.0 };
	V v = { 0.f, -0.f, 0.f, -0.f };
	if (__builtin_copysignf(1.0f, a[0]) != -1.0f || __builtin_copysignf(1.0f, a[2]) != -1.0f) return 1;
	if (__builtin_copysign(1.0, s.x) != -1.0) return 2;
	if (__builtin_copysignf(1.0f, v[1]) != -1.0f || __builtin_copysignf(1.0f, v[0]) != 1.0f) return 3;
	return 0;
}
