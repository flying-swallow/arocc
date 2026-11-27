// #skip: diagnostics differ (aro_c3 gap)
int main(void) {
    char *ö = "ABC"; // #error@11: source file is not valid UTF-8
    return 0;
}

