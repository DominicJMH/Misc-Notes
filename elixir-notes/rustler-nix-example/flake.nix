{
  description = "Elixir project with Rustler NIFs, built with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # crane: Nix library for building Rust projects inside the sandbox
    crane.url = "github:ipetkov/crane";

    # rust-overlay: provides rust-bin.stable.latest.default etc.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, flake-utils, crane, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # Pull in the rust-overlay so we can use pkgs.rust-bin.*
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        # ── Elixir / Erlang ───────────────────────────────────────────────
        # beam.packages groups Elixir/Erlang packages that are built against
        # the same Erlang version. erlang_26 keeps OTP version consistent.
        beamPackages = pkgs.beam.packages.erlang_26;
        elixir = beamPackages.elixir_1_16;

        # ── Rust toolchain ────────────────────────────────────────────────
        # We override the default toolchain to add the musl target.
        # This is required for cross-compiling to x86_64-unknown-linux-musl.
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          targets = [ "x86_64-unknown-linux-musl" ];
        };

        # Build crane using our custom toolchain so it uses the same Rust.
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # ── Project metadata ──────────────────────────────────────────────
        pname = "my_app";
        version = "0.1.0";

        # ── Source filtering ──────────────────────────────────────────────
        # We provide separate filtered sources for the Rust build and the
        # Elixir build to keep derivation inputs minimal and caching optimal.

        # Source for the Rust crate only
        rustSrc = pkgs.lib.cleanSourceWith {
          src = ./native/mycrate;
          filter = path: type:
            builtins.any (ext: pkgs.lib.hasSuffix ext path) [ ".rs" ".toml" ".lock" ]
            || type == "directory";
        };

        # Source for the Elixir project (excludes the native/ Rust directory
        # since that is handled by the Rust derivation separately)
        elixirSrc = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            builtins.any (ext: pkgs.lib.hasSuffix ext path) [ ".ex" ".exs" ".lock" ".nix" ]
            || builtins.elem (builtins.baseNameOf path) [ "mix.exs" "mix.lock" ]
            || type == "directory";
        };

        # ── Linker setup ──────────────────────────────────────────────────
        # pkgsCross.musl64 provides a gcc toolchain that targets musl.
        # Its CC wrapper knows where musl headers/libraries live and produces
        # musl-linked binaries. We use it as the explicit linker for the musl
        # target so cargo doesn't fall back to rust-lld (LLVM's linker), which
        # doesn't know glibc or musl paths in the Nix sandbox.
        muslCC = pkgs.pkgsCross.musl64.stdenv.cc;

        # ── Common Rust build arguments ───────────────────────────────────
        commonArgs = {
          src = rustSrc;
          strictDeps = true;

          # Cross-compile to the musl target.
          # -C target-feature=-crt-static: link dynamically against musl
          # (not a fully static binary) to avoid symbol conflicts with the BEAM.
          CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
          CARGO_BUILD_RUSTFLAGS = "-C target-feature=-crt-static";

          # Explicit linker for the musl target.
          # Without this, cargo uses rust-lld which doesn't know musl paths.
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER =
            "${muslCC}/bin/${muslCC.targetPrefix}cc";

          # Explicit linker for the HOST (x86_64-unknown-linux-gnu).
          # Build scripts (proc-macros, build.rs) compile for the host.
          # In newer Rust (≥1.87), rust-lld is the default linker but it
          # can't find glibc in the Nix sandbox — use the stdenv gcc instead.
          CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER =
            "${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}cc";

          nativeBuildInputs = [
            muslCC          # musl gcc wrapper (for target linking)
            pkgs.stdenv.cc  # glibc gcc wrapper (for host build scripts)
          ];
        };

        # ── Rust build: two-step for caching ──────────────────────────────
        # Step 1: build only the dependencies. This derivation is cached
        # separately, so changing your own Rust code does not invalidate the
        # dependency compilation layer.
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Step 2: build the actual crate, reusing the cached dependency artifacts.
        # Output: /nix/store/…-mycrate/lib/libmycrate.so
        myCrate = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
        });

        # ── Mix (Hex) dependencies ────────────────────────────────────────
        # Generated by running: mix2nix > deps.nix
        # Must be regenerated any time mix.lock changes.
        mixNixDeps = import ./deps.nix { inherit (pkgs) lib; inherit beamPackages; };

        # ── Elixir release derivation ─────────────────────────────────────
        elixirRelease = beamPackages.mixRelease {
          src = elixirSrc;
          inherit pname version mixNixDeps;

          # This env var is read by MyRustlerMacro at compile time (not at
          # runtime). When set, the macro configures Rustler with
          # skip_compilation?: true and load_from: pointing at priv/native/.
          PRECOMPILED_NIF = "true";

          # In nixpkgs's runHook system, the $preConfigure variable runs BEFORE
          # the preConfigureHooks array (which contains mixBuildDirHook).
          # This means we cannot use preConfigure to act on symlinks that
          # mixBuildDirHook hasn't yet created.
          #
          # Instead we override configurePhase entirely, inserting the symlink-
          # expansion logic AFTER mixBuildDirHook runs (inside runHook preConfigure)
          # but BEFORE mix deps.compile.
          #
          # Rustler ≥0.37 reads priv/templates at module compile time
          # (Mix.Tasks.Rustler.New evaluates @external_resource + File.read!
          # inside a module attribute at compile time). When Mix recompiles
          # the dep it replaces the _build/prod/lib/rustler symlink with a
          # real writable directory but only creates ebin/ — leaving priv/
          # absent. By expanding symlinks to real directories (with priv/)
          # before mix deps.compile, the file reads succeed.
          configurePhase = ''
            runHook preConfigure

            # ── Step 1: set up deps/ as writable copies BEFORE mix deps.compile ──
            # Mix finds source files from deps/<name>/ during deps.compile.
            # By setting this up first (as writable copies rather than symlinks
            # to the read-only nix store), we can patch the sources.
            mkdir -p deps
            ${pkgs.lib.concatMapAttrsStringSep "\n" (name: dep: ''
              if [ -d "${dep}/src" ]; then
                cp -r --no-preserve=mode "${dep}/src" "deps/${name}"
                chmod -R u+w "deps/${name}"
              fi
            '') mixNixDeps}

            # ── Step 2: patch rustler source ─────────────────────────────────────
            # mix/tasks/rustler.new.ex reads priv/templates at *compile time*
            # (via @external_resource + File.read! in a module attribute). This
            # is fine locally but breaks in the Nix sandbox because Mix clears
            # and recreates _build/prod/lib/rustler/ during recompilation,
            # discarding the priv/ directory before the compile-time read runs.
            #
            # mix rustler.new is a scaffolding task — it is not needed in a
            # production release. Removing it avoids the compile-time file read.
            rm -f deps/rustler/lib/mix/tasks/rustler.new.ex

            # ── Step 3: expand _build/ symlinks ──────────────────────────────────
            # mixBuildDirHook created symlinks pointing to read-only nix store
            # paths. Expand them to real writable directories so Mix can write
            # compiled beams into them.
            for dep_link in _build/prod/lib/*; do
              if [ -L "$dep_link" ]; then
                real="$(readlink -f "$dep_link")"
                rm "$dep_link"
                cp -r --no-preserve=mode "$real" "$dep_link"
                chmod -R u+w "$dep_link"
              fi
            done

            # ── Step 4: compile deps ──────────────────────────────────────────────
            mix deps.compile --no-deps-check --skip-umbrella-children

            runHook postConfigure
          '';

          # preBuild runs before `mix compile`. We copy the pre-built .so
          # from the Rust derivation's Nix store path into priv/native/ so
          # that it is present when the release is assembled.
          preBuild = ''
            mkdir -p priv/native
            cp ${myCrate}/lib/libmycrate.so priv/native/libmycrate.so
          '';

          meta = with pkgs.lib; {
            description = "Example Elixir app with a Rustler NIF, built with Nix";
            license = licenses.mit;
          };
        };

      in
      {
        # ── Packages ──────────────────────────────────────────────────────
        packages = {
          # `nix build` produces the Elixir release
          default = elixirRelease;

          # `nix build .#mycrate` builds just the Rust NIF
          mycrate = myCrate;
        };

        # ── Development shell ─────────────────────────────────────────────
        # `nix develop` drops you into a shell with all tools available.
        # PRECOMPILED_NIF is intentionally NOT set here, so Rustler will
        # invoke cargo and compile the Rust code normally during `mix compile`.
        devShells.default = pkgs.mkShell {
          buildInputs = [
            elixir
            beamPackages.erlang
            rustToolchain   # includes cargo, rustc, rust-std for musl target
            pkgs.pkg-config
            pkgs.musl       # needed if you compile against musl locally too
          ];

          shellHook = ''
            echo "Dev shell ready."
            echo "  mix deps.get && mix compile  — to build (Rust compiled by cargo)"
            echo "  iex -S mix                   — to start an interactive session"
            echo ""
            echo "PRECOMPILED_NIF is NOT set; Rustler will compile Rust normally."
          '';
        };
      }
    );
}
