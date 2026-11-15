// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wno-implicit-int -std=c17
int foo; // #note@5: previous definition is here // #note@5: previous definition is here

enum {
    foo, // #error@5: redefinition of 'foo' as different kind of symbol
    foo, // #error@5: redefinition of 'foo' as different kind of symbol
};

int foo;

int bar;
int bar = 1; // #note@5: previous definition is here
int bar = 1; // #error@5: redefinition of 'bar'

int baz; // #note@5: previous definition is here
float baz; // #error@7: redefinition of 'baz' with a different type

void func1(int foo, int foo); // #error@25: redefinition of parameter 'foo' // #note@16: previous definition is here
void func2(foo, foo); // #error@17: redefinition of parameter 'foo' // #note@12: previous definition is here // #error@12: identifier parameter lists are only allowed in function definitions
void func3(enum {foo} a, int foo); // #error@30: redefinition of parameter 'foo' // #note@18: previous definition is here

int func4(int[4][4]);
int func4(int[4][4]); // #note@5: previous definition is here
int func4(int[4][3]); // #error@5: redefinition of 'func4' with a different type

int func5(int a) { // #note@15: previous definition is here // #note@5: previous definition is here
    int a; // #error@9: redefinition of 'a'
    return a;
}

int func5(int a) { // #error@5: redefinition of 'func5'
    return 10;
}

int func5(int a);

int arr[2];
int x = 0;
arr[x]; // #error@1: variable length arrays not allowed at file scope

int f1(const int);
int f1(int a) {
    return a;
}
int f2(const int*); // #note@5: previous definition is here
int f2(int *a) { // #error@5: redefinition of 'f2' with a different type
    return *a;
}

struct S {
    struct {
        int a; // #note@13: previous definition is here
    };
    int a; // #error@9: duplicate member 'a' // #note@9: previous definition is here
    float a; // #error@11: duplicate member 'a' // #note@11: previous definition is here
    struct {
        struct {
            int a; // #error@17: duplicate member 'a'
        };
    };
};

typedef int MyInt; // #note@13: previous definition is here
typedef float MyFloat;
typedef MyFloat MyInt; // #error@17: typedef redefinition with different types ('MyFloat' (aka 'float') vs 'int')

typedef int MyOtherInt; // #note@13: previous definition is here
typedef const int MyOtherInt; // #error@19: typedef redefinition with different types ('const int' vs 'int')

int f(int (*)(), double (*)[3]);
int f(int (*)(char *), double (*)[]);

double maximum(int n, int m, double a[n][m]);
double maximum(int n, int m, double a[*][*]);
double maximum(int n, int m, double a[ ][*]);
double maximum(int n, int m, double a[ ][m]);

void f3(double (* restrict a)[5]);
void f3(double a[restrict][5]);
void f3(double a[restrict 3][5]);
void f3(double a[restrict static 3][5]);

int f4(int, ...); // #note@5: previous definition is here
int f4(int); // #error@5: redefinition of 'f4' with a different type

int f5(int (*)(), double (*)[3]); // #note@5: previous definition is here
int f5(int (*)(char), double (*)[]); // not compatible since char undergoes default argument promotion // #error@5: redefinition of 'f5' with a different type

void f6();
void f6(void) {}

void f7(void);
void f7() {}

int X; // #note@5: previous definition is here
enum E {
    X = 4294967295, // #error@5: redefinition of 'X' as different kind of symbol
};

