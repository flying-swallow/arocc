/** manifest:
syntax
args = --target=x86_64-linux-gnu -std=c11
*/

// x86_64-linux-gnu gives int a four-byte size and alignment for these checks.
// A direct cap applies to this record and changes both field offset and size.
#pragma pack(1)
struct pack_one {
	char lead;
	int value;
};
_Static_assert(__builtin_offsetof(struct pack_one, value) == 1, "pack(1) field offset");
_Static_assert(sizeof(struct pack_one) == 5, "pack(1) record size");

// A push with a new cap takes effect, and pop restores the preceding cap.
#pragma pack(push, 2)
struct pack_two {
	char lead;
	int value;
};
_Static_assert(__builtin_offsetof(struct pack_two, value) == 2, "pushed pack(2) field offset");
_Static_assert(sizeof(struct pack_two) == 6, "pushed pack(2) record size");
#pragma pack(pop)
struct pack_restored_one {
	char lead;
	int value;
};
_Static_assert(__builtin_offsetof(struct pack_restored_one, value) == 1, "pop restores pack(1)");
_Static_assert(sizeof(struct pack_restored_one) == 5, "restored pack(1) record size");

// Nested pushes restore the outer cap before the outer pop restores pack(1).
#pragma pack(push, 4)
struct pack_four {
	char lead;
	int value;
};
_Static_assert(__builtin_offsetof(struct pack_four, value) == 4, "pushed pack(4) field offset");
_Static_assert(sizeof(struct pack_four) == 8, "pushed pack(4) record size");
#pragma pack(push, 2)
struct nested_pack_two {
	char lead;
	int value;
};
_Static_assert(__builtin_offsetof(struct nested_pack_two, value) == 2, "nested pack(2) field offset");
#pragma pack(pop)
struct restored_pack_four {
	char lead;
	int value;
};
_Static_assert(__builtin_offsetof(struct restored_pack_four, value) == 4, "nested pop restores pack(4)");
#pragma pack(pop)
struct restored_pack_one {
	char lead;
	int value;
};
_Static_assert(__builtin_offsetof(struct restored_pack_one, value) == 1, "outer pop restores pack(1)");

// An empty pack directive restores natural target alignment.
#pragma pack()
struct natural_alignment {
	char lead;
	int value;
};
_Static_assert(__builtin_offsetof(struct natural_alignment, value) == 4, "natural field alignment restored");
_Static_assert(sizeof(struct natural_alignment) == 8, "natural record size restored");

// Tag declaration attributes are applied before record layout is completed.
struct packed_attribute {
	char lead;
	int value;
} __attribute__((packed));
_Static_assert(__builtin_offsetof(struct packed_attribute, value) == 1, "packed attribute field offset");
_Static_assert(sizeof(struct packed_attribute) == 5, "packed attribute record size");

struct aligned_attribute {
	char lead;
	int value;
} __attribute__((aligned(16)));
_Static_assert(_Alignof(struct aligned_attribute) == 16, "aligned attribute alignment");
_Static_assert(sizeof(struct aligned_attribute) == 16, "aligned attribute record size");
