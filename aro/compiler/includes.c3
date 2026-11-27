module aro::compiler::includes;

enum IncludeKind : char
{
	QUOTE, NORMAL, FRAMEWORK, SYSTEM, SYSTEM_FRAMEWORK, AFTER
}

struct IncludeDir
{
	IncludeKind kind; String path;
}

