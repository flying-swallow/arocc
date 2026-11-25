// #kind: run
// #exit: 0
// C symbols spelled like x86 registers (including segment registers) are quoted
// in Intel-syntax assembly for the system assembler (test_suite_run_system_as).
int gs = 3, rax = 4, cs = 1, mm0 = 2;
static int ss = 5;
int fs(void) { return gs + rax + cs + mm0 + ss; }
int main(void) { return fs() != 15; }
