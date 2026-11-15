// #skip: diagnostics differ (aro_c3 gap)
typedef float Pixel_FFFF[4];
const Pixel_FFFF table[256];
volatile Pixel_FFFF other_table[2];

void invalid(int a[3][const 4]); // #error@19: type qualifier used in non-outermost array type

