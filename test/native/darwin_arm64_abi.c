#include "darwin_arm64_abi.h"
#include <stdarg.h>
int global_array[4] = { 2, 4, 8, 16 };
int *global_pointer = global_array + 2;
struct Pair global_pair = { 9000000000L, -17 };
long narrow_stack(long a,long b,long c,long d,long e,long f,long g,long h,signed char i,short j,int k)
{ return a+b+c+d+e+f+g+h+i+j+k; }
double float_stack(double a,double b,double c,double d,double e,double f,double g,double h,double i,double j)
{ return a+b+c+d+e+f+g+h+i+j; }
struct Pair pair(struct Pair p, int n) { p.a += n; p.b -= n; return p; }
struct Odd odd(struct Odd p) { p.a[1] += 1; return p; }
struct F4 floats(struct F4 p) { p.a += 1; p.b += 2; p.c += 3; p.d += 4; return p; }
struct D4 doubles(struct D4 p) { for (int i=0;i<4;i++) p.a[i] += i; return p; }
struct Large large(struct Large p) { for (int i=0;i<5;i++) p.a[i] += i+1; return p; }
double exhausted(double a,double b,double c,double d,double e,double f,double g,struct D4 p,double z)
{ return a+b+c+d+e+f+g+p.a[0]+p.a[1]+p.a[2]+p.a[3]+z; }
long exhausted_gp(long a,long b,long c,long d,long e,long f,long g,struct Pair p,int z)
{ return a+b+c+d+e+f+g+p.a+p.b+z; }
double variadic(int count, ...)
{
    va_list ap, copy;
    va_start(ap,count); va_copy(copy,ap);
    double total=0;
    for (int i=0;i<count;i++) { total += va_arg(ap,int); total += va_arg(ap,double); }
    total += va_arg(copy,int);
    va_end(copy); va_end(ap); return total;
}
long variadic_named_stack(long a,long b,long c,long d,long e,long f,long g,long h,int n,...)
{ va_list ap; va_start(ap,n); long x = va_arg(ap,long); va_end(ap); return a+b+c+d+e+f+g+h+n+x; }
long variadic_records(int n,...)
{
    va_list ap; va_start(ap,n);
    struct Pair p=va_arg(ap,struct Pair);
    struct Large q=va_arg(ap,struct Large);
    struct D4 d=va_arg(ap,struct D4);
    va_end(ap); return n+p.a+p.b+q.a[4]+(long)d.a[3];
}
signed char small_return(int n) { return n; }
float hfa_stack(float a,float b,float c,float d,float e,float f,float g,float h,long i,long j,long k,long l,long m,long n,long o,long p,signed char q,struct F3 r,signed char s)
{ return a+b+c+d+e+f+g+h+i+j+k+l+m+n+o+p+q+r.a+r.b+r.c+s; }
struct Huge huge(struct Huge p) { p.a[255]+=7; return p; }

unsigned long zero_storage[400];
