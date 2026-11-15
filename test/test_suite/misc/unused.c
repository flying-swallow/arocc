// #opt: -Wunused
void comparisons(void) {
    1 == 1; // #warning@7: equality comparison result unused [-Wunused-comparison]
    1 != 1; // #warning@7: inequality comparison result unused [-Wunused-comparison]
    1 < 1; // #warning@7: relational comparison result unused [-Wunused-comparison]
}

