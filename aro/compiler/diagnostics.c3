// Borrowed diagnostics interface for compiler tooling and frontend adapters.
module aro::compiler::reporting;
import std::collections::list;

enum Severity : char { OFF, NOTE, WARNING, ERROR, FATAL_ERROR }
alias ReportFn = fn void?(void* context, Severity severity, String text, String option);
struct Sink
{
	void* context;
	ReportFn report;
}

// The receiver must copy text if it needs to retain it beyond this call.
fn void? Sink.emit(self, Severity severity, String text, String option = "")
{
	if (self.report) self.report(self.context, severity, text, option)!;
}

struct Report
{
	Severity kind;
	String text;
	String option;
}

// Owning collector for batch jobs and consumers without a language frontend.
struct Collector
{
	Allocator allocator;
	List{Report} messages;
	uint errors;
}

fn void Collector.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.messages.init(allocator);
}

fn void? collect_report(void* context, Severity severity, String text, String option)
{
	Collector* collector = (Collector*)context;
	if (severity == ERROR || severity == FATAL_ERROR) collector.errors++;
	collector.messages.push({ severity, text.copy(collector.allocator), option.copy(collector.allocator) });
}

fn Sink Collector.tooling_sink(&self) => { .context = self, .report = &collect_report };

fn void Collector.free(&self)
{
	foreach (message : self.messages)
	{
		alloc::free(self.allocator, message.text.ptr);
		alloc::free(self.allocator, message.option.ptr);
	}
	self.messages.free();
	*self = {};
}
