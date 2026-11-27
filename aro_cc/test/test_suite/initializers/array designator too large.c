// #skip: diagnostics differ (aro_cc gap)
int arr1[] = { [0x800000000000000 - 1] = 0 }; // #error@14: array is too large
int arr2[] = { [0x800000000000000 - 2] = 0 };
_Static_assert(sizeof(arr1), "");
_Static_assert(sizeof(arr2), "");

