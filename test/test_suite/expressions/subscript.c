int foo(int foo[2]) {
    int arr[4];
    arr[-4] = 4[arr]; // #warning@8: array index -4 is before the beginning of the array [-Warray-bounds] // #warning@16: array index 4 is past the end of the array [-Warray-bounds]
    1[1] = 2; // #error@6: subscripted value is not an array, pointer or vector
    arr[arr] = 2; // #error@8: array subscript is not an integer
    return foo[2]; // #warning@15: array index 2 is past the end of the array [-Warray-bounds]
}

