// #opt: -target x86_64-linux
enum K: char; // #note@6: previous definition is here
enum K: int; // #error@6: enumeration redeclared with different underlying type 'int' (was 'char')
