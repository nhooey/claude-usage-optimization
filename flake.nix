{
  description = "claude-usage-optimization: Rust workspace for ingesting and querying Claude Code transcripts";

  inputs = {
    # Pinned to nixos-unstable so we get a recent rustc available via rust-overlay.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    systems.url = "github:nix-systems/default";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # rust-overlay reads rust-toolchain.toml so the pinned channel + components
    # are the single source of truth for the whole repo (cargo, clippy, rustfmt).
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # crane runs the workspace tests as a Nix sandbox check, with a cached
    # cargoArtifacts derivation (libduckdb-sys + every other workspace
    # dep) so the heavy C++ rebuild is fetched from cache.garnix.io on
    # subsequent pushes instead of recompiled.
    crane.url = "github:ipetkov/crane";
  };

  outputs =
    {
      self,
      flake-parts,
      systems,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;

      imports = [
        inputs.devshell.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        { pkgs, system, ... }:
        let
          # Single source of truth for the Rust toolchain — pinned in
          # rust-toolchain.toml at the repo root.
          rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

          craneLib = (inputs.crane.mkLib pkgs).overrideToolchain rustToolchain;

          # Pre-bake the embedded React viewer so the test build's build.rs
          # can skip its `npm ci && npm run build` step (which needs network
          # access — incompatible with a Nix sandbox check). build.rs's
          # `SKIP_WEB_BUILD=1` branch copies a pre-staged web/dist instead
          # of running npm.
          webDist = pkgs.buildNpmPackage {
            pname = "claude-code-transcripts-web";
            version = "0.0.0";
            src = ./crates/claude-code-transcripts-ingest/web;
            nodejs = pkgs.nodejs_22;
            # Hash of the npm dependency closure (content-addressed via
            # package-lock.json). Update via the fakeHash → real-hash dance
            # whenever package-lock.json changes.
            npmDepsHash = "sha256-TLxGcf+S3JLcZpfB4vZd/SC//mTQwaUMCnO8cwF5eRk=";
            installPhase = ''
              runHook preInstall
              mkdir -p $out
              cp -r dist/. $out/
              runHook postInstall
            '';
          };

          # Common args for every crane invocation. SKIP_WEB_BUILD + the
          # postPatch web/dist staging together let the workspace build
          # without network access in the Nix sandbox.
          commonArgs = {
            src = pkgs.lib.cleanSource ./.;
            strictDeps = true;
            nativeBuildInputs = [
              pkgs.cmake
              pkgs.pkg-config
            ];
            SKIP_WEB_BUILD = "1";
            postPatch = ''
              mkdir -p crates/claude-code-transcripts-ingest/web/dist
              cp -r ${webDist}/. crates/claude-code-transcripts-ingest/web/dist/
              chmod -R u+w crates/claude-code-transcripts-ingest/web/dist
            '';
          };

          # Stubs out workspace crates and compiles only external deps.
          # Cached on cache.garnix.io and reused by every cargoNextest run
          # whose Cargo.lock matches.
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          # Workspace test runner as a Nix sandbox check. Because cargo
          # itself drives the build inside the sandbox, fingerprints match
          # cargoArtifacts cleanly — no fingerprint mismatch like the prior
          # Action-based approach hit when invoking cargo with externally
          # unpacked artifacts.
          cargoTest = craneLib.cargoNextest (
            commonArgs
            // {
              inherit cargoArtifacts;
              partitions = 1;
              partitionType = "count";
            }
          );

          # Clippy across the whole workspace, all targets, deny warnings.
          # Matches the project README's documented dev workflow + the
          # pre-commit hook; without this in CI, lint regressions land.
          cargoClippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--workspace --all-targets -- -D warnings";
            }
          );
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.rust-overlay.overlays.default ];
          };

          packages = {
            inherit cargoArtifacts webDist;
          };

          checks = {
            cargo-test = cargoTest;
            cargo-clippy = cargoClippy;
          };

          treefmt = {
            projectRootFile = "flake.nix";
            # Start with nixfmt only so this PR doesn't reformat the existing
            # Rust / TS / Markdown tree. Add per-language formatters in their
            # own PRs (rustfmt via rustToolchain, taplo, shfmt, prettier) so
            # each formatting sweep is reviewable on its own.
            programs.nixfmt.enable = true;
            settings.global.excludes = [
              "*.lock"
              "LICENSE-*"
              "target/**"
              "crates/*/web/dist/**"
              "crates/*/web/node_modules/**"
            ];
          };

          devshells.default = {
            name = "claude-usage-optimization";

            motd = ''
              {bold}claude-usage-optimization{reset} dev shell — run {bold}menu{reset} for commands.
            '';

            packages = [
              rustToolchain
              # cargo-release drives the version bump + tag flow described in
              # the project README's Release section.
              pkgs.cargo-release
              pkgs.cargo-nextest
              # duckdb (bundled) compiles a C++ source tree from build.rs.
              pkgs.cmake
              pkgs.pkg-config
              # The duckdb CLI is what the agent skills shell out to — required
              # alongside cct itself per the project README.
              pkgs.duckdb
              # build.rs in claude-code-transcripts-ingest invokes `npm` to
              # build the embedded React viewer.
              pkgs.nodejs_22
            ];

            commands = [
              {
                category = "build";
                name = "build";
                help = "cargo build the whole workspace";
                command = "cargo build --workspace \"$@\"";
              }
              {
                category = "build";
                name = "release";
                help = "cargo build --release the whole workspace";
                command = "cargo build --workspace --release \"$@\"";
              }
              {
                category = "check";
                name = "clippy";
                help = "cargo clippy across the workspace, all targets, deny warnings";
                command = "cargo clippy --workspace --all-targets -- -D warnings \"$@\"";
              }
              {
                category = "check";
                name = "test";
                help = "cargo test the whole workspace";
                command = "cargo test --workspace \"$@\"";
              }
              {
                category = "format";
                name = "fmt";
                help = "run treefmt across every supported file in the repo (nix fmt)";
                command = "nix fmt \"$@\"";
              }
              {
                category = "run";
                name = "cct";
                help = "cct CLI passthrough — try cct-ingest / cct-serve / cct-info, or `cct --help`";
                command = "cargo run --quiet --release -p claude-code-transcripts-ingest --bin cct -- \"$@\"";
              }
              {
                category = "run";
                name = "cct-ingest";
                help = "ingest ~/.claude/projects into ~/.local/share/cct/transcripts.duckdb";
                command = "cargo run --quiet --release -p claude-code-transcripts-ingest --bin cct -- ingest \"$@\"";
              }
              {
                category = "run";
                name = "cct-serve";
                help = "serve the embedded transcript viewer at http://localhost:8766";
                command = "cargo run --quiet --release -p claude-code-transcripts-ingest --bin cct -- serve \"$@\"";
              }
              {
                category = "run";
                name = "cct-info";
                help = "print DB path, size, entry / session counts, last ingest timestamp";
                command = "cargo run --quiet --release -p claude-code-transcripts-ingest --bin cct -- info \"$@\"";
              }
              {
                category = "update";
                name = "update-flake";
                help = "refresh flake.lock to the latest pinned input revisions";
                command = "nix flake update \"$@\"";
              }
            ];
          };
        };
    };
}
