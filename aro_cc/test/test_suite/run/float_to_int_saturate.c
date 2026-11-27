// #kind: run
// #exit: 0
/* Constant float-to-int folds that overflow saturate to the destination's
   min/max, matching GCC's fold (gcc.c-torture/execute/20031003-1.c,
   PR optimization/9325). Returns a failure bitmask. */
int f1(void) { return (int)2147483648.0f; } // #warning@23: conversion of out of range value from 'float' to 'int' is undefined; folded to 2147483647 [-Wliteral-conversion]
int f2(void) { return (int)(float)(2147483647); } // #warning@23: conversion of out of range value from 'float' to 'int' is undefined; folded to 2147483647 [-Wliteral-conversion]
int f3(void) { return (int)-1e10; } // #warning@23: conversion of out of range value from 'double' to 'int' is undefined; folded to -2147483648 [-Wliteral-conversion]
signed char f4(void) { return (signed char)300.0; } // #warning@31: conversion of out of range value from 'double' to 'signed char' is undefined; folded to 127 [-Wliteral-conversion]

int main(void)
{
	int fail = 0;
	if (f1() != 2147483647) fail |= 1;
	if (f2() != 2147483647) fail |= 2;
	if (f3() != -2147483647 - 1) fail |= 4;
	if (f4() != 127) fail |= 8;
	return fail;
}
