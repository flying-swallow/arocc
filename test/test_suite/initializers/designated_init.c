// #skip: diagnostics differ (aro_c3 gap)
union U {
    int a;
    float b;
} __attribute__((designated_init)); // #error@18: 'designated_init' attribute is only valid on 'struct' type'
struct S {
    int a;
    float b;
} __attribute__((designated_init)) a = { 1 }; // #warning@42: positional initialization of field in 'struct' declared with 'designated_init' attribute [-Wdesignated-init]

