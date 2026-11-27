#include "darwin_arm64_abi.h"
extern int printf(const char *, ...);
static long recurse(long n) { return n < 2 ? 1 : n * recurse(n-1); }
static int vla(int n) { int a[n]; for (int i=0;i<n;i++) a[i]=i*3; return a[n-1]; }
static int big_frame(int n) { volatile unsigned char a[20000]; a[0]=n; a[19999]=n+1; return a[0]+a[19999]; }
static long cycle(int n) { long a=1,b=2; while(n--) { long t=a; a=b; b=t; } return a*10+b; }
int main(void)
{
    if (narrow_stack(1,2,3,4,5,6,7,8,-3,-300,12345)!=12078) return 1;
    if (float_stack(1,2,3,4,5,6,7,8,9,10)!=55) return 2;
    struct Pair p={100,-7}; p=pair(p,12); if(p.a!=112||p.b!=-19) return 3;
    struct Odd o={{10,20,30}}; o=odd(o); if(o.a[0]!=10||o.a[1]!=21||o.a[2]!=30) return 4;
    struct F4 f={1,2,3,4}; f=floats(f); if(f.a!=2||f.b!=4||f.c!=6||f.d!=8) return 5;
    struct D4 d={{1,2,3,4}}; d=doubles(d); if(d.a[0]!=1||d.a[1]!=3||d.a[2]!=5||d.a[3]!=7) return 6;
    struct Large l={{1,2,3,4,5}}; l=large(l); if(l.a[0]!=2||l.a[4]!=10) return 7;
    if(exhausted(1,2,3,4,5,6,7,d,9)!=53) return 8;
    if(exhausted_gp(1,2,3,4,5,6,7,p,9)!=130) return 9;
    if(variadic(2,3,1.5,7,2.5)!=17) return 10;
    if(variadic_named_stack(1,2,3,4,5,6,7,8,9,100L)!=145) return 11;
    if(variadic_records(1,p,l,d)!=111) return 12;
    if(*global_pointer!=8||global_array[3]!=16||global_pair.a!=9000000000L||global_pair.b!=-17) return 13;
    struct Pair (*fp)(struct Pair,int)=pair; p=fp(p,5); if(p.a!=117||p.b!=-24) return 14;
    if(recurse(7)!=5040||vla(23)!=66||big_frame(5)!=11||cycle(7)!=21) return 15;
    volatile double zero=0; double nan=zero/zero;
    if(nan==nan||nan<zero||nan<=zero||nan>zero||nan>=zero||!(nan!=nan)) return 16;
    for(int i=-30;i<30;i++) for(int j=-9;j<9;j++) if(j && (i/j*j+i%j!=i)) return 17;
    if(small_return(-3)!=-3) return 18;
    struct F3 f3={1,2,3};
    if(hfa_stack(1,2,3,4,5,6,7,8,1,2,3,4,5,6,7,8,-3,f3,-5)!=70) return 19;
    struct Huge huge_value = {{0}}; huge_value.a[0]=42; huge_value=huge(huge_value);
    if(huge_value.a[0]!=42||huge_value.a[255]!=7) return 20;
    if(zero_storage[0]||zero_storage[399]) return 21;
    zero_storage[399]=123; if(zero_storage[399]!=123) return 22;
    printf("ARM64 ABI passed: %ld %.1f\n", p.a, f.d);
    return 0;
}
