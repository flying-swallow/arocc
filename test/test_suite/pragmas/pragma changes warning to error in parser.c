#pragma GCC diagnostic error "-Wint-conversion"
void foo(void) {
	int *x = 5; // #error@11: implicit integer to pointer conversion from 'int' to 'int *' [-Werror,-Wint-conversion]
}

