// #opt: --target=x86_64-linux-gnu -std=c11 --emulate=clang
/** manifest:
syntax
args = --target=x86_64-linux-gnu -std=c11 --emulate=clang
*/

struct pack_change_inside_record {
	char lead;
#pragma pack(1)
	int value;
};

_Static_assert(__builtin_offsetof(struct pack_change_inside_record, value) == 4,
	"clang/default keeps the record's initial natural alignment");
_Static_assert(sizeof(struct pack_change_inside_record) == 8,
	"clang/default record size uses natural alignment");

#pragma pack()
