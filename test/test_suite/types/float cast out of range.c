/* Explicit float-to-int casts of out-of-range constants are undefined
   (C23 6.3.1.4p1); the fold saturates like GCC and says so. */
int a = (int)2147483648.0f; // #warning@9: conversion of out of range value from 'float' to 'int' is undefined; folded to 2147483647 [-Wliteral-conversion]
int b = (int)(float)2147483647; // #warning@9: conversion of out of range value from 'float' to 'int' is undefined; folded to 2147483647 [-Wliteral-conversion]
int c = (int)-1e10; // #warning@9: conversion of out of range value from 'double' to 'int' is undefined; folded to -2147483648 [-Wliteral-conversion]
signed char d = (signed char)300.0; // #warning@17: conversion of out of range value from 'double' to 'signed char' is undefined; folded to 127 [-Wliteral-conversion]
unsigned e = (unsigned)-1.0; // #warning@14: conversion of out of range value from 'double' to 'unsigned int' is undefined; folded to 0 [-Wliteral-conversion]
int f = (int)1.5;
