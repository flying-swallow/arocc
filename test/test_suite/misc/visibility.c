int __attribute__((visibility("default"))) default_func(void) {
	return 0;
}

int __attribute__((visibility("hidden"))) hidden_global;

int __attribute__((visibility("none"))) bad_visibility; // #warning@31: unknown 'visibility' argument. Possible values are: "hidden", "default", "internal", and "protected" [-Wignored-attributes]

