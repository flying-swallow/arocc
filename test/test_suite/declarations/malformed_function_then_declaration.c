int broken(void) { if (1) } // #error@27: expected statement // #warning@27: non-void function 'broken' does not return a value
int valid;
