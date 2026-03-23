# Getting Rustler + Nix to Build: A Step-by-Step Debug Log

This document records every error encountered when building the example project from scratch, what caused each one, and exactly how it was fixed. It is meant as a companion to `rustler-nix-guide.md` — where the guide explains the *concepts*, this log explains the *pain*.

---

## Starting Point

The goal: build an Elixir Mix release that loads a Rust NIF (via Rustler), entirely inside the Nix sandbox, using:
- `crane` for the Rust crate
- `beamPackages.mixRelease` for the Elixir release
- `mix2nix` for Hex dependency management
- `rust-overlay` for a pinned Rust toolchain with the musl target

We created `flake.nix`, `mix.exs`, `lib/my_rustler_macro.ex`, `lib/my_rustler.ex`, `native/mycrate/Cargo.toml`, and `native/mycrate/src/lib.rs`.

Initial command: `nix flake check`

---

## Error 1 — Missing `Cargo.lock`

### What happened

```
error: unable to find Cargo.lock at /nix/store/n8pwa32g8d3k7lqmqnliiqilqc7jp66d-mycrate.
please ensure one of the following:
  - a Cargo.lock exists at the root of the source directory
```

### Why it happens

Crane requires a `Cargo.lock` to reproduce the dependency graph deterministically. Without it, crane doesn't know which exact versions of crates to fetch or how to verify the dependency closure. It refuses to proceed rather than silently picking arbitrary versions.

### Fix

Run `cargo generate-lockfile` (using a nix-provided cargo since cargo isn't installed globally):

```bash
nix shell nixpkgs#cargo --command cargo generate-lockfile \
  --manifest-path native/mycrate/Cargo.toml
```

This creates `native/mycrate/Cargo.lock`. Commit this file — it must live alongside `Cargo.toml` and be kept in sync with it.

---

## Error 2 — Inverted source filter (`hasSuffix` argument order)

### What happened

After adding `Cargo.lock`, the flake evaluated but the crane build failed:

```
error: could not find `Cargo.toml` in `/build/source` or any parent directory
```

### Why it happens

The source filter in `flake.nix` was written as:

```nix
filter = path: type:
  builtins.any (pkgs.lib.hasSuffix path) [ ".rs" ".toml" ".lock" ]
  || type == "directory";
```

`pkgs.lib.hasSuffix` has signature `hasSuffix suffix str`. The call `hasSuffix path` partially applies it, producing a function that checks whether its argument *ends with `path`*. That is backwards — `path` is the string being tested, not the suffix. So `builtins.any (hasSuffix path) [".rs" ".toml" ".lock"]` was checking whether each extension string ended with `path`, which is always false. The filter was excluding every file including `Cargo.toml`.

### Fix

Flip the argument order — the extension goes first, the path goes second:

```nix
filter = path: type:
  builtins.any (ext: pkgs.lib.hasSuffix ext path) [ ".rs" ".toml" ".lock" ]
  || type == "directory";
```

Applied the same fix to the Elixir source filter.

---

## Error 3 — `rust-lld` can't find glibc symbols in the Nix sandbox

### What happened

With the filters fixed, the crane build started but failed during dependency compilation with a flood of linker errors:

```
rust-lld: error: undefined symbol: openat64
  >>> referenced by unix.rs:2602 in archive .../libstd-267b04dbd87607fb.rlib

rust-lld: error: undefined symbol: readdir64
rust-lld: error: undefined symbol: stat64
rust-lld: error: undefined symbol: gnu_get_libc_version

error: could not compile `proc-macro2` (build script) due to 1 previous error
```

### Why it happens

Two things combined to cause this:

1. **The musl target requires a dedicated C linker.** When compiling for `x86_64-unknown-linux-musl`, cargo needs a C linker that knows how to produce musl-linked binaries. Without one explicitly configured, cargo defaults to `rust-lld` (LLVM's linker), which doesn't know where musl's libc lives in the Nix sandbox.

2. **Newer Rust (≥1.87) made `rust-lld` the default linker on Linux.** Build scripts (like proc-macro2's `build.rs`) compile for the *host* target (`x86_64-unknown-linux-gnu`). `rust-lld` is used for these too, but it can't find glibc's shared libraries in the Nix sandbox (glibc is not in standard paths on NixOS). This is what produces the `openat64`, `stat64`, etc. "undefined symbol" errors — those are glibc-internal symbols that rust-lld is trying to resolve but can't find.

The original `flake.nix` only put `pkgs.musl` in `nativeBuildInputs`, which provides the musl C library but not a properly configured linker wrapper.

### Fix

Set explicit linkers for *both* the musl target and the GNU host target:

```nix
# pkgsCross.musl64 provides a gcc wrapper pre-configured to produce
# musl-linked binaries, including the correct sysroot and library paths.
muslCC = pkgs.pkgsCross.musl64.stdenv.cc;

commonArgs = {
  # ... other args ...

  CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER =
    "${muslCC}/bin/${muslCC.targetPrefix}cc";

  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER =
    "${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}cc";

  nativeBuildInputs = [
    muslCC          # musl gcc wrapper (for the NIF target)
    pkgs.stdenv.cc  # glibc gcc wrapper (for build scripts on the host)
  ];
};
```

- `CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER`: tells cargo to use the musl cross-compiler for linking the actual NIF shared library.
- `CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER`: tells cargo to use gcc (which knows where glibc lives) for linking build scripts that run on the host.
- Removed `pkgs.musl` — it was providing the wrong kind of musl support (just the C library headers, not a proper cross-linker wrapper).

---

## Error 4 — Empty `mixNixDeps` / `rustler` module not found

### What happened

The Rust NIF now built successfully (`nix build .#mycrate` produced `libmycrate.so`). Attempting the full release (`nix build`) failed:

```
== Compilation error in file lib/my_rustler.ex ==
** (CompileError) lib/my_rustler.ex: cannot compile module MyRustler
    error: module Rustler is not loaded and could not be found
```

### Why it happens

The `mixNixDeps` attribute was set to `{}` (an empty set, placeholder). When `beamPackages.mixRelease` builds the Elixir release, it needs all Hex dependencies available offline — including `rustler` (the Elixir library that provides the `use Rustler` macro). With an empty `mixNixDeps`, there were no deps; `use Rustler` failed because the `Rustler` module didn't exist.

### Fix

**Step 1 — Generate `mix.lock`** by actually fetching deps (requires a network-connected shell, done outside the Nix sandbox):

```bash
nix shell nixpkgs#elixir_1_16 nixpkgs#mix2nix --command sh -c \
  "mix local.hex --force && mix deps.get"
```

This resolves deps and writes `mix.lock`. The resolved versions were:
- `rustler 0.37.3`
- `jason 1.4.4` (rustler's dependency)

**Step 2 — Generate `deps.nix`** from the lockfile:

```bash
nix shell nixpkgs#mix2nix --command mix2nix > deps.nix
```

`mix2nix` reads each entry in `mix.lock`, emits a Nix expression using `beamPackages.buildMix` and `fetchHex` with the correct SHA256 hashes.

**Step 3 — Update `Cargo.toml`** to match the resolved Hex rustler version. The mix deps resolved `rustler 0.37.3`, so the Rust crate should use the matching version:

```toml
rustler = "0.37"
```

Then regenerate `Cargo.lock`:

```bash
nix shell nixpkgs#cargo --command cargo update \
  --manifest-path native/mycrate/Cargo.toml
```

**Step 4 — Update `flake.nix`** to import the real `deps.nix`:

```nix
mixNixDeps = import ./deps.nix { inherit (pkgs) lib; inherit beamPackages; };
```

---

## Error 5 — `rustler ≥0.37` reads template files at module compile time

### What happened

With real deps, the build progressed further but failed during `mix deps.compile` inside the `mixRelease` build:

```
==> rustler
Compiling 7 files (.ex)

== Compilation error in file lib/mix/tasks/rustler.new.ex ==
** (File.Error) could not read file
  "/build/source/_build/prod/lib/rustler/priv/templates/basic/README.md":
  no such file or directory
    lib/mix/tasks/rustler.new.ex:33: anonymous fn/3 in :elixir_compiler_26.__MODULE__/1
    lib/mix/tasks/rustler.new.ex:30: (module)
```

### Why it happens — a multi-layer problem

This was the hardest error to diagnose. Several things interact:

#### Layer 1: What `rustler.new.ex` does

Looking at the rustler 0.37.3 source:

```elixir
# lib/mix/tasks/rustler.new.ex
root = Path.join(:code.priv_dir(:rustler), "templates/")

for {format, source, _} <- @basic ++ @root do
  if format != :keep do
    @external_resource Path.join(root, source)
    defp render(unquote(source)), do: unquote(File.read!(Path.join(root, source)))
  end
end
```

`root = ...` and `File.read!(...)` are evaluated at **module compile time** — they're inside a `for` comprehension that produces module attributes and function definitions. They run when `mix compile` (or `mix deps.compile`) compiles this `.ex` file. This is normal Elixir metaprogramming; it embeds the template content into the compiled BEAM bytecode so `mix rustler.new` can work offline.

#### Layer 2: How nixpkgs `mixRelease` sets up the build environment

`mixBuildDirHook` (a nixpkgs setup hook that runs before `configurePhase`) reads `$ERL_LIBS` and creates symlinks:

```
_build/prod/lib/rustler → /nix/store/.../rustler-0.37.3/lib/erlang/lib/rustler-0.37.3
```

The nix store path has both `ebin/` (compiled beams) and `priv/` (with `templates/basic/README.md`).

#### Layer 3: Why Mix recompiles rustler anyway

The nixpkgs-built rustler package's `ebin/` directory has no `.mix/compile.elixir` manifest file — nixpkgs's `buildMix` doesn't produce these Mix-internal tracking files. When Mix sees compiled beams without a manifest, it can't verify they're current, so it decides to recompile from source.

Mix finds source in `deps/rustler/`, which the `mix-release.nix` configurePhase sets up (after `mix deps.compile` in the original) by symlinking `${dep}/src` → `deps/<name>`. Wait — that's set up *after* `mix deps.compile`… but Mix finds 7 files anyway. This is because nixpkgs's `buildMix` includes the source in `$out/src/`, and the setup hook makes those paths available through `$ERL_LIBS`-adjacent mechanisms.

#### Layer 4: The actual failure

When Mix recompiles rustler, it:
1. Clears and recreates `_build/prod/lib/rustler/` — this is the existing symlink (pointing to the nix store)
2. Creates a fresh `ebin/` directory inside the new real directory
3. Does **not** recreate `priv/`

So when `rustler.new.ex` is compiled, `:code.priv_dir(:rustler)` returns `_build/prod/lib/rustler/priv`, but that directory no longer exists — Mix cleared it in step 1.

#### Why `preConfigure` didn't work

First attempt: add the fix in `preConfigure`. This failed silently because of nixpkgs's hook execution order:

```
runHook preConfigure
├── _callImplicitHook preConfigure  ← evaluates $preConfigure variable FIRST
└── preConfigureHooks[@]            ← runs mixBuildDirHook SECOND
```

`$preConfigure` runs *before* `mixBuildDirHook` creates the symlinks, so there were no symlinks to operate on. The code ran silently against a non-existent `_build/prod/lib/` directory and did nothing.

#### Why the `configurePhase` symlink expansion didn't work alone

Second attempt: override `configurePhase` to expand the `_build/prod/lib/` symlinks to real directories (with `priv/` intact) before `mix deps.compile`. Debug output confirmed the expansion worked:

```
_build/prod/lib/rustler/priv/templates/basic/README.md  ← present, readable
```

But `mix deps.compile` *still* failed with the same error. The reason: Mix was clearing the `_build/prod/lib/rustler/` directory as part of its recompile cycle (step 1 above), then building a fresh `ebin/`-only structure. No matter how carefully we pre-populate `priv/`, Mix wipes it out before the compile-time read.

### Fix — the right approach

Rather than fighting Mix's cleanup of `_build/`, remove the problematic file from the *source* before Mix compiles it:

1. **Set up `deps/` as writable copies *before* `mix deps.compile`**:
   ```bash
   mkdir -p deps
   cp -r --no-preserve=mode "${dep}/src" "deps/${name}"
   chmod -R u+w "deps/${name}"
   ```
   (For each dep in `mixNixDeps`.)

2. **Delete `deps/rustler/lib/mix/tasks/rustler.new.ex`**:
   ```bash
   rm -f deps/rustler/lib/mix/tasks/rustler.new.ex
   ```
   This file is the `mix rustler.new` scaffolding task. It is *not* part of the runtime Rustler library — it's a developer convenience tool for generating new NIF project skeletons. Removing it from the source before compilation means Mix never tries to compile it, never tries to read the template files, and the build succeeds.

3. **Still expand `_build/prod/lib/` symlinks** to real writable directories so Mix can write compiled beams:
   ```bash
   for dep_link in _build/prod/lib/*; do
     if [ -L "$dep_link" ]; then
       real="$(readlink -f "$dep_link")"
       rm "$dep_link"
       cp -r --no-preserve=mode "$real" "$dep_link"
       chmod -R u+w "$dep_link"
     fi
   done
   ```

4. **Override `configurePhase`** (not `preConfigure`) to run these steps in the correct order, after `runHook preConfigure` (which includes `mixBuildDirHook`).

The full override in the `mixRelease` call:

```nix
configurePhase = ''
  runHook preConfigure
  # ← mixBuildDirHook has now run, _build/prod/lib/ symlinks exist

  # Step 1: set up deps/ as writable copies
  mkdir -p deps
  ${pkgs.lib.concatMapAttrsStringSep "\n" (name: dep: ''
    if [ -d "${dep}/src" ]; then
      cp -r --no-preserve=mode "${dep}/src" "deps/${name}"
      chmod -R u+w "deps/${name}"
    fi
  '') mixNixDeps}

  # Step 2: patch rustler — remove compile-time file-reading task
  rm -f deps/rustler/lib/mix/tasks/rustler.new.ex

  # Step 3: expand _build/ symlinks to real writable directories
  for dep_link in _build/prod/lib/*; do
    if [ -L "$dep_link" ]; then
      real="$(readlink -f "$dep_link")"
      rm "$dep_link"
      cp -r --no-preserve=mode "$real" "$dep_link"
      chmod -R u+w "$dep_link"
    fi
  done

  # Step 4: compile deps
  mix deps.compile --no-deps-check --skip-umbrella-children

  runHook postConfigure
'';
```

---

## Final Result

After all five fixes, both builds succeed:

```bash
nix build .#mycrate  # → result/lib/libmycrate.so (411K, musl-linked NIF)
nix build            # → result/ (full Elixir release with NIF embedded)
nix flake check      # → all outputs evaluate cleanly, no warnings
```

Checking the release:

```
result/
├── bin/my_app
├── erts-14.2.5.13/
├── lib/
│   └── my_app-0.1.0/
│       └── priv/
│           └── native/
│               └── libmycrate.so   ← the Rust NIF, compiled via crane
└── releases/
```

`file result/lib/my_app-0.1.0/priv/native/libmycrate.so`:
```
ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked
```

---

## Summary of All Fixes

| # | Error | Root Cause | Fix |
|---|-------|------------|-----|
| 1 | `Cargo.lock` not found | Crane requires a lockfile | Run `cargo generate-lockfile` |
| 2 | `Cargo.toml` not found in source | `hasSuffix` args were inverted in source filter | `(ext: hasSuffix ext path)` instead of `(hasSuffix path)` |
| 3 | `undefined symbol: openat64` (linker) | Rust ≥1.87 defaults to `rust-lld`; host build scripts can't find glibc; no musl linker | Set `CARGO_TARGET_*_LINKER` for both musl and gnu targets using `pkgsCross.musl64.stdenv.cc` and `stdenv.cc` |
| 4 | `module Rustler is not loaded` | `mixNixDeps = {}` — no Hex packages available | Generate `mix.lock` + `deps.nix` via `mix deps.get` + `mix2nix` |
| 5 | `priv/templates/basic/README.md: no such file` | `rustler.new.ex` reads template files at compile time; Mix clears `_build/lib/rustler/priv/` before recompiling | Override `configurePhase`: copy deps to writable dirs, delete `rustler.new.ex` from source before `mix deps.compile` |

---

## Key Nix / nixpkgs Mechanics Learned

**Hook execution order in `runHook preConfigure`:**
The `$preConfigure` environment variable runs *before* `preConfigureHooks[@]`. `mixBuildDirHook` is in `preConfigureHooks`. Therefore `preConfigure` cannot see the `_build/` symlinks that `mixBuildDirHook` creates — you must act on them in the `configurePhase` body, after `runHook preConfigure` returns.

**`mixBuildDirHook` only creates `_build/` symlinks:**
It reads `$ERL_LIBS` and symlinks each OTP library directory into `_build/$MIX_BUILD_PREFIX/lib/`. It does not set up `deps/`. The `deps/` source symlinks are set up later in the nixpkgs `configurePhase` (after `mix deps.compile`).

**`buildMix` does not produce Mix compile manifests:**
The nixpkgs `buildMix` derivation produces `ebin/` (beams) and `priv/` in its output, but not the `.mix/compile.elixir` tracking files that Mix uses to detect whether a dep needs recompilation. As a result, Mix always recompiles deps from source in a `mixRelease` build. This is usually harmless — but not when the dep source has compile-time side effects.

**Cargo musl cross-compilation needs `pkgsCross.musl64`:**
`pkgs.musl` provides only the musl C library headers. To actually link against musl, you need a gcc wrapper configured with the musl sysroot, which is `pkgs.pkgsCross.musl64.stdenv.cc`. Its `targetPrefix` attribute gives you the correct binary name (e.g., `x86_64-unknown-linux-musl-cc`).
