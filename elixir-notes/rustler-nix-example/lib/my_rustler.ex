defmodule MyRustler do
  @moduledoc """
  NIF module backed by a Rust implementation.

  At compile time, `MyRustlerMacro.rustler_use()` injects the correct
  `use Rustler, ...` configuration depending on the `PRECOMPILED_NIF`
  environment variable (see `MyRustlerMacro` for full details).

  Each function declared here must have a corresponding `#[rustler::nif]`
  annotation in the Rust source. The default implementations below simply
  raise `:nif_not_loaded`, which the BEAM calls if the NIF fails to load
  at startup — making startup failures obvious rather than silent.
  """

  # Must require before calling the macro.
  require MyRustlerMacro

  # This single call expands to `use Rustler, ...` with the correct options
  # chosen at compile time based on PRECOMPILED_NIF.
  MyRustlerMacro.rustler_use()

  # ── NIF declarations ───────────────────────────────────────────────────
  # Each function here is a placeholder. The real implementation lives in
  # native/mycrate/src/lib.rs and is loaded by Rustler at startup.
  # If the NIF library fails to load, :erlang.nif_error/1 is called instead,
  # raising an error with the given atom.

  @doc "Adds two integers together (implemented in Rust)."
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns the length of a binary (implemented in Rust)."
  def binary_len(_bin), do: :erlang.nif_error(:nif_not_loaded)
end
