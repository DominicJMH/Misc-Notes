defmodule MyRustlerMacro do
  @moduledoc """
  A compile-time macro that selects the correct Rustler configuration
  depending on whether we are building inside a Nix sandbox or locally.

  ## How it works

  `use Rustler, ...` is a compile-time call — it is evaluated when the
  Elixir compiler processes the module that calls it, not when the
  application starts at runtime.

  We exploit this to read the `PRECOMPILED_NIF` environment variable at
  compile time. In a Nix `mixRelease` build, that variable is set to "true"
  in the derivation attributes. In a normal `mix compile` during development,
  it is not set.

  Based on that check, the macro injects one of two `use Rustler, ...` calls
  into the calling module's AST:

    - **Nix build** (`PRECOMPILED_NIF=true`): tells Rustler to skip invoking
      cargo (`skip_compilation?: true`) and to load the library from a known
      path inside the OTP `priv/` directory (`load_from:`).

    - **Development**: tells Rustler to compile the Rust crate normally using
      cargo, pointing at the `native/mycrate` directory.

  ## Usage

      defmodule MyRustler do
        require MyRustlerMacro
        MyRustlerMacro.rustler_use()

        def my_function(arg), do: :erlang.nif_error(:nif_not_loaded)
      end
  """

  @doc """
  Inject the appropriate `use Rustler` call based on the build environment.

  Must be called at the top level of the module body, after `require MyRustlerMacro`.
  """
  defmacro rustler_use() do
    # System.get_env/2 runs here, at macro expansion time (i.e., compile time).
    use_precompiled = System.get_env("PRECOMPILED_NIF", "false")

    cond do
      use_precompiled in ["true", "1"] ->
        # ── Nix build path ────────────────────────────────────────────────
        # skip_compilation?: true   → do not invoke cargo during compilation.
        # load_from:                → at runtime, load the .so from this OTP
        #                             app priv path. Rustler appends the
        #                             platform-appropriate extension (.so,
        #                             .dylib, .dll) automatically.
        quote do
          use Rustler,
            otp_app: :my_app,
            skip_compilation?: true,
            load_from: {:my_app, "priv/native/libmycrate"}
        end

      true ->
        # ── Development path ──────────────────────────────────────────────
        # crate:   name of the Rust crate (must match [package] name in Cargo.toml)
        # path:    path to the crate directory, relative to the Mix project root
        # target:  Rust compile target — using musl keeps dev consistent with prod
        quote do
          use Rustler,
            otp_app: :my_app,
            crate: "mycrate",
            path: "native/mycrate",
            target: "x86_64-unknown-linux-musl"
        end
    end
  end
end
