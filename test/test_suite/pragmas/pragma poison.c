#define foo bar
#pragma GCC poison "bar" foo // #error@20: can only poison identifier tokens
#pragma GCC poison bar

int foo;
int bar; // #error@5: attempt to use a poisoned identifier

#define baz(x)

baz(bar) // #error@5: attempt to use a poisoned identifier

#pragma GCC poison baz // #warning@20: poisoning existing macro

