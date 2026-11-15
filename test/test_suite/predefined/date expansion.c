// #opt: -Wdate-time
char *foo = __DATE__; // #warning@13: expansion of date or time macro is not reproducible [-Wdate-time]

