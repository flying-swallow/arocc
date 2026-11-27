// #skip: diagnostics differ (aro_cc gap)
// #todo: TODO: implement 'asm_label' attribute
register int a; // #error@15: register name not specified for global variable
register int b __asm__("ebp"); // #warning@16: TODO: implement 'asm_label' attribute

