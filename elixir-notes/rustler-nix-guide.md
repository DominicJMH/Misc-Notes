# Using Rustler with Nix: A Complete Guide

Source: https://sidhion.com/blog/using_rustler_nix/

---

## Background: What Is Rustler?

Rustler is an Elixir library that allows you to write **Native Implemented Functions (NIFs)** in Rust. NIFs are functions implemented in C (or any language with a C-compatible ABI) that are loaded directly into the BEAM (Erlang VM) process. When called, they run as native code — no message passing, no process boundary — making them suitable for CPU-intensive work that would be too slow in pure Elixir.

Rustler provides:
- Macros to declare Rust functions as NIFs.
- A build step (via `mix compile`) that invokes `cargo` to compile your Rust crate into a shared library (`.so` on Linux, `.dylib` on macOS, `.dll` on Windows).
- Automatic loading of that shared library into the BEAM at startup.

The key detail: **Rustler kicks off `cargo` during `mix compile`**. This is transparent in a normal development setup but becomes a problem in Nix.

---

## Background: What Is Nix (and Why Does It Cause Problems)?

Nix is a purely functional package manager and build system. Its central guarantee is **reproducibility**: given the same inputs, a Nix build always produces the same output, on any machine. It achieves this through a **sandboxed build environment**:

- **No network access**: The build process cannot reach the internet. All dependencies must be declared as Nix inputs and fetched before the build starts.
- **Restricted filesystem**: Only explicitly declared paths are visible.
- **No ambient tools**: `cargo`, `gcc`, `git`, etc. are not available unless explicitly listed as `buildInputs` or `nativeBuildInputs`.

This is the direct conflict with Rustler: `cargo` normally downloads crates from crates.io during compilation. In the Nix sandbox, that download will fail. Even if you somehow provide `cargo`, it still can't reach the registry.

---

## The Solution at a Glance

The blog post's solution separates the build into two independent Nix derivations:

1. **Rust derivation** — builds the Rust crate using `crane`, which knows how to pre-fetch and cache all Cargo dependencies as Nix inputs. Output: `libmycrate.so`.

2. **Elixir derivation** — builds the Mix release using `beamPackages.mixRelease`. Before Mix compiles anything, the pre-built `.so` is copied into the `priv/native/` directory. An environment variable (`PRECOMPILED_NIF`) tells the Elixir code to skip invoking `cargo` and to load the already-compiled library instead.

For **development**, you use `nix develop` (or `nix shell`) to get a shell with `cargo`, Elixir, and Erlang available. In that shell, Rustler compiles Rust the normal way.

---

## Deep Dive: Crane

[Crane](https://github.com/ipetkov/crane) is a Nix library for building Rust projects. It solves the Cargo-in-sandbox problem by:

1. **Pre-fetching all Cargo dependencies** as a fixed-output derivation (Nix's mechanism for content-addressed network fetches). This is the only step that touches the network.
2. **Building dependencies separately** (`buildDepsOnly`) — producing a `cargoArtifacts` output that contains the compiled dependency artifacts.
3. **Building your crate** (`buildPackage`) using those pre-built artifacts, entirely offline.

This two-step split (`buildDepsOnly` → `buildPackage`) also gives you Nix-level caching: if your dependencies haven't changed, step 1 is a cache hit and step 2 builds only your code.

### Why musl?

The blog post targets `x86_64-unknown-linux-musl`. Here's why:

- **musl** is a lightweight C standard library. Linking against it produces binaries that are more self-contained than those linked against glibc.
- For NIFs specifically, the `.so` must be loadable by the BEAM. If the BEAM itself is linked against glibc but your NIF is linked against a static musl, you can run into symbol conflicts.
- The flag `-C target-feature=-crt-static` disables fully static linking, so the output is a *dynamically linked musl* binary. This is the sweet spot: portable, but not creating static-vs-dynamic conflicts with the runtime.
- You need `musl` (the C library + headers) available in the build environment for the Rust cross-compile to musl to work.

---

## Deep Dive: The `PRECOMPILED_NIF` Macro Trick

This is the most subtle part. Understanding *why* it works requires knowing when Elixir macros are evaluated.

### Compile-Time vs. Runtime

In Elixir, `use SomeModule` expands to a macro call at **compile time** — specifically, during `mix compile`, not when your app starts. So any `System.get_env/1` call inside a macro runs when the compiler processes the source file, not when the application boots.

This means:
- If `PRECOMPILED_NIF` is set in the shell environment during `mix compile`, the macro sees it.
- If it's not set, the macro takes the other branch.
- The resulting compiled BEAM bytecode is different depending on which branch was taken.

In the Nix `mixRelease` derivation, `PRECOMPILED_NIF = "true"` is set as a Nix attribute, which propagates it to the build environment. So when `mix compile` runs inside the Nix sandbox, the macro sees the env var and configures Rustler to skip `cargo`.

### The Two Rustler Configurations

**When `PRECOMPILED_NIF` is true (Nix build):**

```elixir
use Rustler,
  otp_app: :my_app,
  skip_compilation?: true,
  load_from: {:my_app, "priv/native/libmycrate"}
```

- `skip_compilation?: true` — do not invoke `cargo`. This is what prevents the sandbox failure.
- `load_from: {:my_app, "priv/native/libmycrate"}` — tells Rustler exactly where the `.so` file lives. Rustler will resolve this to the `priv/native/libmycrate.so` (or `.dylib`, etc.) file inside your app's OTP directory at runtime.

**When `PRECOMPILED_NIF` is not set (development):**

```elixir
use Rustler,
  otp_app: :my_app,
  crate: "mycrate",
  path: "../mycrate",
  target: "x86_64-unknown-linux-musl"
```

- `crate` — the name of the Rust crate (matches `[package] name` in `Cargo.toml`).
- `path` — path to the crate directory, relative to the Elixir project root. Conventionally this is `native/mycrate`, but adjust as needed.
- `target` — the Rust compilation target. Using the musl target here keeps dev and production consistent.

### Why a Macro Instead of Plain `if`?

You might wonder: why wrap this in a `defmacro` instead of using a regular `if` or `cond` directly in the module?

The answer is that `use Rustler, ...` must be a **compile-time** call. In Elixir, only macros can inject code at compile time. A regular function call like `if ..., do: use Rustler, ...` would not work because `use` itself is a macro that must be called at the top level of a module's compile phase.

The pattern:

```elixir
defmodule MyRustlerMacro do
  defmacro rustler_use() do
    use_precompiled = System.get_env("PRECOMPILED_NIF", "false")
    cond do
      use_precompiled in ["true", "1"] ->
        quote do
          use Rustler, otp_app: :my_app, skip_compilation?: true, load_from: {:my_app, "priv/native/libmycrate"}
        end
      true ->
        quote do
          use Rustler, otp_app: :my_app, crate: "mycrate", path: "native/mycrate", target: "x86_64-unknown-linux-musl"
        end
    end
  end
end
```

When `MyRustlerMacro.rustler_use()` is called inside `MyRustler`, the macro body runs at compile time, checks the env var, and injects the appropriate `use Rustler, ...` call into the module's AST.

---

## Deep Dive: `mixRelease` and `preBuild`

`beamPackages.mixRelease` is Nixpkgs' builder for Mix releases. It runs `mix deps.compile` and `mix release` inside the Nix sandbox. By default, it expects all Mix dependencies to be available offline via `mixNixDeps` (generated by tools like `mix2nix` or `mix-to-nix`).

The `preBuild` hook runs *before* `mix compile`. This is where you copy the pre-built NIF into place:

```nix
preBuild = ''
  mkdir -p priv/native
  cp ${myCrate}/lib/libmycrate.so priv/native/libmycrate.so
'';
```

The `${myCrate}` is a Nix store path — the output of the crane derivation. Nix substitutes this with the actual path (e.g., `/nix/store/xxxxx-mycrate-0.1.0`) at build time. The `lib/` subdirectory is where cargo places `.so` files by default.

After `preBuild`, when Mix compiles the Elixir code:
1. The macro sees `PRECOMPILED_NIF=true` and configures Rustler to skip compilation.
2. The `.so` already exists at `priv/native/libmycrate.so`.
3. The final Mix release packages up `priv/native/` along with everything else, so the `.so` is available at runtime.

---

## Deep Dive: `mixNixDeps` and Dependency Management

`mixNixDeps` is a Nix attribute set mapping Hex package names to their Nix derivations. Without it, `mix deps.get` inside the sandbox would try to download from Hex.pm and fail.

Tools that generate this:
- **`mix2nix`** (`github:sagax/mix2nix`) — reads `mix.lock` and generates a `deps.nix` file.
- **`mix-to-nix`** — a similar tool with slightly different ergonomics.

The generated file looks like:

```nix
# deps.nix (auto-generated, do not edit by hand)
{
  rustler = {
    version = "0.30.0";
    sha256 = "sha256-...";
    # ...
  };
  # other deps...
}
```

In `flake.nix`, you import it:

```nix
mixNixDeps = import ./deps.nix { inherit lib beamPackages; };
```

---

## Project Structure

```
my_app/
├── flake.nix                 # Nix build + dev shell definition
├── flake.lock                # Nix flake lockfile (auto-generated)
├── mix.exs                   # Mix project config
├── mix.lock                  # Hex dependency lockfile
├── deps.nix                  # Generated by mix2nix from mix.lock
├── lib/
│   ├── my_app/
│   │   └── application.ex    # OTP Application module
│   ├── my_rustler_macro.ex   # Compile-time macro for NIF config
│   └── my_rustler.ex         # The NIF module itself
└── native/
    └── mycrate/
        ├── Cargo.toml         # Rust crate manifest
        └── src/
            └── lib.rs         # Rust NIF implementation
```

---

## Development Workflow

1. Enter the dev shell: `nix develop`
2. Fetch Mix dependencies: `mix deps.get`
3. Compile: `mix compile` (Rustler invokes `cargo` automatically)
4. Run: `iex -S mix`

Because `PRECOMPILED_NIF` is *not* set in the dev shell, Rustler takes the normal compilation path.

## Production / Nix Build Workflow

1. Generate `deps.nix`: `mix2nix > deps.nix` (run after any change to `mix.lock`)
2. Build: `nix build` — this builds both the Rust NIF and the Elixir release
3. The result is at `./result/`, which is a symlink into the Nix store

---

## Potential Gotchas

### `.so` filename must match exactly
The `load_from` path must match the actual filename Cargo produces. Cargo names the output `lib<crate_name>.so`. If your crate is named `mycrate`, the file is `libmycrate.so`. Be precise.

### musl target requires explicit linker configuration
Do NOT use `pkgs.musl` in `nativeBuildInputs`. Instead, use `pkgs.pkgsCross.musl64.stdenv.cc` as the musl-target linker and `pkgs.stdenv.cc` for the host (build script) linker. Set both via `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER` and `CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER`. In newer Rust (≥1.87), `rust-lld` became the default linker, but it cannot find glibc symbols in the Nix sandbox, causing host-target build scripts to fail at link time.

### The macro branch is baked into the BEAM at compile time
If you compile with `PRECOMPILED_NIF=true` and then try to run that build without the `.so`, it will fail at app startup — not at compile time. Conversely, if you compile without `PRECOMPILED_NIF`, Rustler will try to invoke `cargo` at startup (actually at compile time of the module), which will fail in a sandboxed environment.

### `mix2nix` must be re-run after `mix.lock` changes
`deps.nix` is generated from `mix.lock`. After adding or updating deps (`mix deps.get`), regenerate `deps.nix` before running `nix build`.

### Nix sandbox always re-builds derivations (no artifact reuse)
Unlike local builds where Rustler caches compiled artifacts in `_build/`, every Nix build starts fresh. This is by design — it's what guarantees reproducibility. The crane two-step (`buildDepsOnly` as a cached layer) mitigates this for the dependency compilation phase.

### Rustler ≥0.37: `mix rustler.new` reads templates at compile time
In `rustler` Hex package ≥0.37, the `Mix.Tasks.Rustler.New` module reads template files via `File.read!` inside a module attribute (i.e., at compile time, not at runtime). In a `mixRelease` build, `mix deps.compile` recompiles rustler from source. Mix clears the `_build/prod/lib/rustler/` directory during recompilation, removing the `priv/` directory before the compile-time file read runs — causing a "no such file or directory" error.

**Fix**: Set up `deps/` as writable copies (not symlinks) *before* `mix deps.compile`, then delete `deps/rustler/lib/mix/tasks/rustler.new.ex` from the writable copy. The `mix rustler.new` task is only needed for generating new NIF scaffolding and is not part of the runtime library; removing it from the source before compilation has no effect on the finished release.

This requires overriding `configurePhase` in the `mixRelease` call rather than using `preConfigure` — because in nixpkgs's hook system, the `$preConfigure` environment variable runs *before* `preConfigureHooks` (including `mixBuildDirHook`), so any action on the `_build/` symlinks must go in the main `configurePhase` body, after `runHook preConfigure` has completed.
