// #skip: diagnostics differ (aro_cc gap)
int a = 0b; // #error@9: invalid suffix 'b' on integer constant
int b = 0x; // #error@9: invalid suffix 'x' on integer constant
int c = 0b12; // #error@9: invalid digit '2' in binary constant
int d = 0b1.2; // #error@9: invalid suffix '.2' on integer constant
double e = 019.5;
double f = 0x12.e; // #error@12: hexadecimal floating constant requires an exponent
int g = 0128; // #error@9: invalid digit '8' in octal constant
int h = 0iull;
int i = 1e; // #error@9: exponent has no digits
double j = 0x1p; // #error@12: exponent has no digits
int k = 123LLuf; // #error@9: invalid suffix 'LLuf' on integer constant
float l = 12e+2f;
float m = 12E-2f;
float n = 0x12P+2;
float o = 0x12p-2;
_Static_assert(0xE+0xC == 0xE + 0xC, ""); // #error@16: invalid suffix '+0xC' on integer constant
double p = 0x1.ep-1;
double q = 0x1.eP-1;
double r = 0x1.Ep-1;
double s = 0x1.EP-1;
double t = 1.ep-1; // #error@12: exponent has no digits
double u = 1.pp-1; // #error@12: invalid suffix 'pp-1' on floating constant

