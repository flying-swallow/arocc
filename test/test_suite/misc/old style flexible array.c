struct S1 {
    int a[1];
    int b[1];
};

struct S2 {
    int x;
    struct S1 s1[1];
};

void foo(struct S1 *p) {
    struct S1 s1;
    s1.a[1] = 0; // #warning@9: array index 1 is past the end of the array [-Warray-bounds]
    s1.b[1] = 0;
    p->a[1] = 0; // #warning@9: array index 1 is past the end of the array [-Warray-bounds]
    p->b[1] = 0;

    struct S2 s2;
    s2.s1[2].a[1] = 0; // #warning@15: array index 1 is past the end of the array [-Warray-bounds]
    s2.s1[2].b[1] = 0;
}

struct S3 {
    int w;
    struct {
        int x;
        int y[1];
        int z[1];
    };
};

void bar(struct S3 *p) {
    p->y[1] = 0; // #warning@9: array index 1 is past the end of the array [-Warray-bounds]
    p->z[1] = 0;
    struct S3 s3;
    s3.y[1] = 0; // #warning@9: array index 1 is past the end of the array [-Warray-bounds]
    s3.z[1] = 0;
}

#pragma GCC diagnostic warning "-Wold-style-flexible-struct"
void baz(void) {
    struct S1 s1;
    s1.b[0] = 1;
    s1.b[1] = 1; // #warning@9: array index 1 is past the end of the array [-Wold-style-flexible-struct]
}

