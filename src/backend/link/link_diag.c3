// Diagnostics and shared failures for the in-process linker.
module aro::backend::link;
import aro::diagnostics;
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

<*
 Linker diagnostic text. File-oriented entries take a path; parser errors also
 take a reason so callers can report the failure without retaining
 parser-specific state.
*>
enum LinkDiag : ushort (String fmt, MessageKind kind, DiagMeta meta)
{
	CANNOT_OPEN { "cannot open %s", ERROR, {} },
	MALFORMED_ELF { "%s: malformed ELF file: %s", ERROR, {} },
	UNSUPPORTED_ELF { "%s: unsupported ELF file: %s", ERROR, {} },
	MALFORMED_ARCHIVE { "malformed archive %s: %s", ERROR, {} },
	UNSUPPORTED_ARCHIVE { "unsupported archive %s: %s", ERROR, {} },
	MALFORMED_SCRIPT { "%s:%d: %s", ERROR, {} },
	UNSUPPORTED_SCRIPT { "unsupported linker script %s: %s", ERROR, {} },
	MALFORMED_LD_ARGS { "in-process linker: %s", NOTE, {} },
	UNSUPPORTED_LD_ARG { "in-process linker does not support '%s'; using the system linker", NOTE, {} },
	LIBRARY_NOT_FOUND { "cannot find -l%s", ERROR, {} },
}

<*
 Format and send a linker diagnostic. A null sink is allowed for standalone
 linker use; otherwise Diagnostics owns the message copy made by add().
 The diagnostic must be an enum constant so @format checks its arguments.
*>
macro void? @link_err(Diagnostics* d, LinkDiag $diag, ...)
{
	if (!d || !d.@enabled($diag)) return;
	@pool() { return d.add(diagnostics::@message($diag, string::tformat($diag.fmt, ...$vaarg))); };
}
