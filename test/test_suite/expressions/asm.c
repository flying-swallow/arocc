// #todo: TODO: implement 'asm_label' attribute
void foo(void) __asm__("foo"); // #warning@16: TODO: implement 'asm_label' attribute
__asm__ volatile volatile("foo"); // #error@9: meaningless 'volatile' on assembly outside function // #error@18: meaningless 'volatile' on assembly outside function // #error@18: duplicate asm qualifier 'volatile'
__asm__(u8"nop"); // #error@9: cannot use unicode string literal in assembly
__asm__(L"nop"); // #error@9: cannot use wide string literal in assembly
__asm__(5); // #error@9: expected string literal in 'asm'

