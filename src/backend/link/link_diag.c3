// Diagnostics and shared failures for the in-process linker.
module aro::backend::link;
import aro::frontend::c::diagnostics;
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
 Format and send a linker diagnostic. A null sink is allowed for standalone
 linker use; otherwise Diagnostics owns the message copy made by add().
 The diagnostic must be an enum constant so @format checks its arguments.
*>
macro void? @link_err(Diagnostics* d, Diagnostic $diag, ...)
{
	if (!d || !d.@enabled($diag)) return;
	@pool() { return d.add(diagnostics::@message($diag, string::tformat($diag.fmt, ...$vaarg))); };
}
