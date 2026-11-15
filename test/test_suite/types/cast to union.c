// #skip: diagnostics differ (aro_c3 gap)
union U {
    int x;
    float y;
};
union Forward;

void foo(void) {
    union U u;
#pragma GCC diagnostic push
#pragma GCC diagnostic warning "-Wpedantic"
    u = (union U)1; // #warning@9: cast to union type is a GNU extension [-Wgnu-union-cast]
#pragma GCC diagnostic pop

    u = (union U)1.0f;
    u = (union U)1.0; // #error@9: cast to union type from type 'double' not present in union
    (union Forward)1; // #error@5: cast to incomplete type 'union Forward'
    (union DoesNotExist)1; // #error@5: cast to incomplete type 'union DoesNotExist'
}

void same_type_casts(union U value, _Atomic(union U) atomic_value) {
    (void)(union U)value;
    (void)(_Atomic(union U))value;
    (void)(union U)atomic_value;
    (void)(_Atomic(union U))atomic_value;
}

union Forward make_forward(void);

void incomplete_same_type_cast(void) {
    (void)(union Forward)make_forward(); // #error@11: cast to incomplete type 'union Forward'
}

