#define SCALE(x) ((x) * 3)
struct Item { int value; struct Item *next; };
int sum(struct Item *item) { return SCALE(item->value); }
