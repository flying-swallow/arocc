/** manifest:
syntax
args = --target=x86_64-linux-gnu -std=c11 --emulate=gcc
*/

struct pack_change_inside_record {
	char lead;
#pragma pack(1)
	int value;
};

_Static_assert(__builtin_offsetof(struct pack_change_inside_record, value) == 1,
	"GCC applies the in-body pack change to the following field");
_Static_assert(sizeof(struct pack_change_inside_record) == 5,
	"GCC packs the following field without tail padding");

#pragma pack()
