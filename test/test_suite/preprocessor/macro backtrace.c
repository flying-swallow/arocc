// #skip: diagnostics differ (aro_cc gap)
// #note: <scratch space>:1:1: expanded from here
#define a 1 ## 2 // #note@11: expanded from here
#define b a
#define c b
#define d c
#define e d
#define f e
#define g f
#define h g
#define i h
#define j i
#define k j
a // #error@1: expected external declaration
b
c
d
e
f
g
h
i
j
k

