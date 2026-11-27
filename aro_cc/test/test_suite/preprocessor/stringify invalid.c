void foo(void) {

#define str(s) # s
#define xstr(s) str(s)

#define INCFILE(n) "ok\ // #warning@20: missing terminating '"' character [-Winvalid-pp-token]
vers ## n

xstr(INCFILE(a))
} // #error@1: expected ';', found '}'

