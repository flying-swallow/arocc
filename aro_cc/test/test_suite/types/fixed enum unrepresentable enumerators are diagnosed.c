// #opt: -target x86_64-linux
enum E3: unsigned char {
 A = 255,
 B, // #error@2: enumerator value is not representable in the underlying type 'unsigned char'
};
enum E4: char {
 A = 256, // #error@2: enumerator value is not representable in the underlying type 'char'
};
