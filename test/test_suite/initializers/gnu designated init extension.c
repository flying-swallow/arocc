int x[] = {[1] 2, [3] 4}; // #warning@16: use of GNU 'missing =' extension in designator [-Wgnu-designator] // #warning@23: use of GNU 'missing =' extension in designator [-Wgnu-designator]
_Static_assert(sizeof(x) == sizeof(int[4]), "Incorrect array size");

