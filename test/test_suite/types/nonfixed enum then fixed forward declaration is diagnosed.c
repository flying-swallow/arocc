// #opt: -target x86_64-linux
enum G; // #note@6: previous definition is here
enum G: int; // #error@6: enumeration previously declared with nonfixed underlying type
