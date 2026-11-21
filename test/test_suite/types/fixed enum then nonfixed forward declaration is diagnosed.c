// #opt: -target x86_64-linux
enum H: int; // #note@6: previous definition is here
enum H; // #error@6: enumeration previously declared with fixed underlying type
