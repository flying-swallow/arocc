// #opt: -fno-gnu-inline-asm
__asm__("foo"); // #error@8: GNU-style inline assembly is disabled
__asm__("");

