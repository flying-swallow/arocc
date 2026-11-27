// Diagnostics and shared failures for the in-process linker.
module aro::backend::link;
import aro::compiler::reporting;
import std::core::string;

excuse FILE_NOT_FOUND;
excuse MALFORMED_ELF;
excuse UNSUPPORTED_ELF;
excuse MALFORMED_ARCHIVE;
excuse UNSUPPORTED_ARCHIVE;
excuse MALFORMED_SCRIPT;
excuse UNSUPPORTED_SCRIPT;
excuse MALFORMED_LD_ARGS;
excuse UNSUPPORTED_LD_ARG;
excuse LIBRARY_NOT_FOUND;

// Formatting remains compile-time checked; the receiver owns presentation policy.
enum LinkDiagnostic : char(String fmt, reporting::Severity severity)
{
	CANNOT_OPEN { "cannot open %s", ERROR },
	MALFORMED_ELF { "%s: malformed ELF file: %s", ERROR },
	UNSUPPORTED_ELF { "%s: unsupported ELF file: %s", ERROR },
	MALFORMED_ARCHIVE { "malformed archive %s: %s", ERROR },
	UNSUPPORTED_ARCHIVE { "unsupported archive %s: %s", ERROR },
	MALFORMED_SCRIPT { "%s:%d: %s", ERROR },
	UNSUPPORTED_SCRIPT { "unsupported linker script %s: %s", ERROR },
	MALFORMED_LD_ARGS { "in-process linker: %s", NOTE },
	UNSUPPORTED_LD_ARG { "in-process linker does not support '%s'; using the system linker", NOTE },
	LIBRARY_NOT_FOUND { "cannot find -l%s", ERROR },
}

macro void? @link_err(reporting::Sink d, LinkDiagnostic $diag, ...)
{
	if (!d.report) return;
	@pool() { d.emit($diag.severity, string::tformat($diag.fmt, ...$vaarg))!; };
}
