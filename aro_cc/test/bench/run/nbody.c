/* N-body step with doubles: floating multiply/add/divide, sqrt. */
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
int main(void)
{
	int n = 5;
	double *x = calloc(n * 7, sizeof(double));
	if (!x) return 1;
	double *y = x + n, *z = x + 2 * n, *vx = x + 3 * n, *vy = x + 4 * n, *vz = x + 5 * n, *m = x + 6 * n;
	for (int i = 0; i < n; i++)
	{
		x[i] = i * 1.5;
		y[i] = i * -0.75 + 0.5;
		z[i] = (i % 2) * 0.25;
		vx[i] = 0.01 * i;
		vy[i] = -0.02 * i;
		vz[i] = 0.005;
		m[i] = 1.0 + i * 0.1;
	}
	double dt = 0.001;
	for (int step = 0; step < 1000000; step++)
	{
		for (int i = 0; i < n; i++)
			for (int j = i + 1; j < n; j++)
			{
				double dx = x[i] - x[j], dy = y[i] - y[j], dz = z[i] - z[j];
				double d2 = dx * dx + dy * dy + dz * dz + 0.01;
				double mag = dt / (d2 * sqrt(d2));
				vx[i] -= dx * m[j] * mag;
				vy[i] -= dy * m[j] * mag;
				vz[i] -= dz * m[j] * mag;
				vx[j] += dx * m[i] * mag;
				vy[j] += dy * m[i] * mag;
				vz[j] += dz * m[i] * mag;
			}
		for (int i = 0; i < n; i++)
		{
			x[i] += dt * vx[i];
			y[i] += dt * vy[i];
			z[i] += dt * vz[i];
		}
	}
	double e = 0;
	for (int i = 0; i < n; i++) e += m[i] * (vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i]);
	printf("%.6f\n", e);
	free(x);
	return 0;
}
