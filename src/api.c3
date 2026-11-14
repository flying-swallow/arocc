// Public facade aliases for the module exports in src/aro.zig and src/backend.zig.
// Kept out of the root `aro` module: C3 exposes parent-module symbols to every
// aro::* submodule, which made these aliases ambiguous with the real types.
module aro::api;

import aro::backend::assembly, aro::backend::ir, aro::backend::object;
import aro::code_gen_options, aro::codegen, aro::compilation, aro::diagnostics;
import aro::driver, aro::parser, aro::preprocessor, aro::source;
import aro::string_interner, aro::target, aro::tokenizer, aro::toolchain;
import aro::tree, aro::type_store, aro::value, aro::value_interner;

// Zig src/aro.zig module exports and named type aliases.
alias CodeGen = codegen::CodeGen;
alias Compilation = compilation::Compilation;
alias Diagnostics = diagnostics::Diagnostics;
alias Parser = parser::Parser;
alias Preprocessor = preprocessor::Preprocessor;
alias Source = source::Source;
alias StringInterner = string_interner::StringInterner;
alias Target = target::Target;
alias Tokenizer = tokenizer::Tokenizer;
alias Toolchain = toolchain::Toolchain;
alias Tree = tree::Tree;
alias TypeStore = type_store::TypeStore;
alias QualType = type_store::QualType;
alias Type = type_store::Type;
alias Value = value::Value;

// Zig src/backend.zig exports, implemented by C3 backend modules.
alias Interner = value_interner::Interner;
alias Ir = ir::Ir;
alias Object = object::Object;
alias Assembly = assembly::Assembly;
alias CodeGenOptions = code_gen_options::CodeGenOptions;
