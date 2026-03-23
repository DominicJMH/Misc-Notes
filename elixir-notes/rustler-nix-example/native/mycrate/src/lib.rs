// This is the Rust NIF implementation.
// Each function annotated with #[rustler::nif] is exported as an Erlang NIF.
// The function signatures use Rustler's type system to decode Erlang terms
// into Rust types and encode the return value back into an Erlang term.

use rustler::Binary;

// ── NIF implementations ────────────────────────────────────────────────────

/// Adds two i64 integers and returns the result.
/// Called from Elixir as: MyRustler.add(a, b)
#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

/// Returns the byte length of a binary.
/// Called from Elixir as: MyRustler.binary_len(bin)
#[rustler::nif]
fn binary_len(bin: Binary) -> usize {
    bin.len()
}

// ── NIF registration ───────────────────────────────────────────────────────
// rustler::init! registers all NIFs with the Erlang runtime.
// The first argument is the name of the Elixir module (as an atom string).
// The second argument is a list of the Rust functions to export.
//
// The module name here must match the Elixir module that calls `use Rustler`.
rustler::init!("Elixir.MyRustler", [add, binary_len]);
