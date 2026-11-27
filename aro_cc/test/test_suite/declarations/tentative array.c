int arr[];

_Static_assert(sizeof arr,""); // #error@16: invalid application of 'sizeof' to an incomplete type 'int []'

struct arr;
struct arr arr_1;
struct arr {
    int arr;
};

int arr[3];

_Static_assert(sizeof arr == 3 * sizeof(int),"");

