// ANSI terminal escape sequences (colors and styles).
module aro::ansi;

<* Escape sequences copied from std/Io/Terminal.zig `setColor`. *>
enum Color : char(String code)
{
	WHITE { "\e[37m" },
	BRIGHT_RED { "\e[91m" },
	BRIGHT_YELLOW { "\e[93m" },
	BRIGHT_BLUE { "\e[94m" },
	BRIGHT_GREEN { "\e[92m" },
	BRIGHT_MAGENTA { "\e[95m" },
	BRIGHT_CYAN { "\e[96m" },
	BOLD { "\e[1m" },
	RESET { "\e[0m" },
}
