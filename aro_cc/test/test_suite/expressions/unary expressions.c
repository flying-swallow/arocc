// #skip: diagnostics differ (aro_cc gap)
void foo(void) {
    (void)+1;
    +(int*)1; // #error@5: invalid argument type 'int *' to unary expression
    (void)-1.0;
    -(int*)1; // #error@5: invalid argument type 'int *' to unary expression
    int a, *b;
    ++a;
    --b;
    a--;
    b++;
    1++; // #error@6: expression is not assignable
    --1; // #error@5: expression is not assignable
    const int c;
    ++c; // #error@5: expression is not assignable
    c--; // #error@6: expression is not assignable
    (void)~1;
    ~2.0; // #error@5: invalid argument type 'double' to unary expression
    ~(void)1; // #error@5: invalid argument type 'void' to unary expression
    (void)!a;
    (void)!b;
    (void)!(void)1; // #error@11: invalid argument type 'void' to unary expression
    (void); // #error@11: expected expression
    register int d;
    &d; // #error@5: address of register variable requested
    _Complex double e;
    (void) __imag__ e;
    (void) __real a;
    (void) __real__ b; // #error@12: invalid type 'int *' to __real operator
    struct S {
        int x: 4;
    } s;
    (void)&(s.x); // #error@11: address of bit-field requested
}

typedef struct Hmm {
    inl n; // invalid type // #error@5: unknown type name 'inl'
} Hmm;

static int explode1 = &((Hmm *)1337)->n;
static int explode2 = *((Hmm *)1337)->n;
static int explode3 = +((Hmm *)1337)->n;
static int explode4 = -((Hmm *)1337)->n;
static int explode5 = ++((Hmm *)1337)->n;
static int explode6 = --((Hmm *)1337)->n;
static int explode7 = ~((Hmm *)1337)->n;
static int explode8 = !((Hmm *)1337)->n;
static int explode9 = ((Hmm *)1337)->n--;
static int explode10 = ((Hmm *)1337)->n++;

