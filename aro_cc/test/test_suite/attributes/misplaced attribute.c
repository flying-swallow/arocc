// #skip: diagnostics differ (aro_cc gap)
 __attribute__ ((aligned (8))) struct S { short f[3]; }; // #warning@18: attribute 'aligned' is ignored, place it after "struct" to apply attribute to type declaration [-Wignored-attributes]
 __attribute__ ((packed)) union U { int x; }; // #warning@18: attribute 'packed' is ignored, place it after "union" to apply attribute to type declaration [-Wignored-attributes]
 __attribute__ ((aligned)) enum E { e }; // #warning@18: attribute 'aligned' is ignored, place it after "enum" to apply attribute to type declaration [-Wignored-attributes]

