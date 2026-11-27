// #kind: run
// #exit: 0
/* Check that variadic float promotion and double formatting produce the
   expected snprintf result. */
#include <stdio.h>
#include <string.h>

int main(void)
{
	char output[64];
	int length = snprintf(output, sizeof output, "f=%.2f d=%.3f", 1.25f, -2.5);
	return length == 15 && strcmp(output, "f=1.25 d=-2.500") == 0 ? 0 : 1;
}
