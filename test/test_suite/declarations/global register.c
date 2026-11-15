// #skip: diagnostics differ (aro_c3 gap)
// #todo: TODO: implement 'asm_label' attribute
register int a; // #error@15: register name not specified for global variable
register int b __asm__("ebp"); // #warning@16: TODO: implement 'asm_label' attribute

