# A development shell that builds the source tree in place, so that rebuilds only compile what changed.
#
#   nix develop                  # enter the shell (or: nix develop -c ladybird-dev run)
#   ladybird-dev build           # configure on first use, then build incrementally into Build/nix
#   ladybird-dev run [args...]   # build, then run Ladybird
#   ladybird-dev configure [-DOPTION=value...]
#                                # configure again from scratch, with further CMake options if given
{
  lib,
  stdenv,
  mkShell,
  writeShellApplication,
  writeShellScript,
  writeText,
  ccache,
  icu78,
  qt6Packages,
  ladybird,
}:

let
  inherit (ladybird.passthru) devSupport;

  # Ladybird builds its Rust code with -Dwarnings, for the Rust version rust-toolchain.toml names. nixpkgs' newer Rust
  # deprecates APIs that code uses, so this drops -Dwarnings, as postPatch in nix/package.nix does to the tree.
  # Cargo runs it as: rustc-allow-warnings <rustc> <arguments...>
  rustcAllowWarnings = writeShellScript "rustc-allow-warnings" ''
    arguments=()
    while (($#)); do
      if [[ $1 == -Dwarnings ]]; then
        shift
      elif [[ $1 == -D && ''${2-} == warnings ]]; then
        shift 2
      else
        arguments+=("$1")
        shift
      fi
    done
    exec "''${arguments[@]}"
  '';

  # The same configuration as nix/package.nix. The edits its postPatch makes to the tree are replaced by flags and by
  # devSupport here. Network downloads stay on, as in upstream's own development builds.
  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    (lib.cmakeBool "ENABLE_LTO_FOR_RELEASE" false)
    # Like the package, leave out the tests. GCC, which nixpkgs builds with, fails some of them with warnings that
    # upstream, building with Clang, does not see.
    (lib.cmakeBool "BUILD_TESTING" false)
    (lib.cmakeFeature "ICU_ROOT" (toString icu78.dev))
    (lib.cmakeFeature "PDFJS_DIR" (toString devSupport.pdfjs))
    (lib.cmakeFeature "RUSTC_WRAPPER" (toString rustcAllowWarnings))
    # Ladybird compiles through ccache when it finds it (LADYBIRD_ENABLE_CCACHE), so that switching branches or
    # rebuilding from scratch reuses what was compiled before.
    (lib.cmakeFeature "CCACHE_PROGRAM" (lib.getExe ccache))
  ];

  # Every dependency the build directory refers to. CMake records their store paths in its cache, so ladybird-dev
  # keeps them from being garbage collected, and configures from scratch whenever they change.
  devInputs = writeText "ladybird-dev-inputs" (
    lib.concatMapStringsSep "\n" toString (
      lib.unique (
        lib.concatMap
          (package: [
            package
            (lib.getDev package)
            (lib.getLib package)
          ])
          (
            ladybird.buildInputs
            ++ ladybird.nativeBuildInputs
            ++ [
              icu78
              devSupport.pdfjs
              devSupport.ffmpegPkgConfigAliases
              rustcAllowWarnings
              ccache
            ]
          )
      )
    )
  );

  ladybird-dev = writeShellApplication {
    name = "ladybird-dev";
    text = ''
      if [[ ! -f flake.nix || ! -d Meta/CMake ]]; then
        echo "ladybird-dev: run this from the root of the Ladybird source tree" >&2
        exit 1
      fi

      build_dir="''${LADYBIRD_DEV_BUILD_DIR:-Build/nix}"
      flags=${lib.escapeShellArg (lib.concatStringsSep " " (cmakeFlags ++ [ "inputs=${devInputs}" ]))}
      flags_stamp="$build_dir/.ladybird-dev-flags"

      configure() {
        # --fresh drops the cached results of earlier runs, which name the store paths of the dependencies then.
        # What was compiled stays, and ccache makes recompiling what did change cheap. Further arguments go to CMake.
        cmake --fresh -G Ninja -S . -B "$build_dir" ${lib.escapeShellArgs cmakeFlags} "$@"
        if command -v nix-store > /dev/null; then
          nix-store --add-root "$build_dir/.nix-dev-inputs" --realise ${devInputs} > /dev/null
        else
          echo "ladybird-dev: nix-store not found, so garbage collection may remove what this build uses" >&2
        fi
        printf '%s\n' "$flags" > "$flags_stamp"
      }

      build() {
        # Configure again whenever the flags or the dependencies changed, e.g. after updating the flake.
        if [[ ! -f "$build_dir/build.ninja" || "$(cat "$flags_stamp" 2>/dev/null)" != "$flags" ]]; then
          configure
        fi
        ninja -C "$build_dir"
      }

      command="''${1:-build}"
      shift || true
      case "$command" in
        configure) configure "$@" ;;
        build) build ;;
        run)
          build
          exec "$build_dir/bin/Ladybird" "$@"
          ;;
        *)
          echo "usage: ladybird-dev [configure|build|run [args...]]" >&2
          exit 1
          ;;
      esac
    '';
  };
in
mkShell {
  inputsFrom = [ ladybird ];
  packages = [
    ladybird-dev
    ccache
    devSupport.ffmpegPkgConfigAliases
  ];

  env = {
    # As in nix/package.nix.
    NIX_LDFLAGS = devSupport.ldflags;
    # The packaged Ladybird gets its Qt plugins, such as the Wayland platform, from the wrapper wrapQtAppsHook adds.
    # A Ladybird run from Build/nix has no wrapper, so the shell provides them.
    QT_PLUGIN_PATH = lib.makeSearchPath qt6Packages.qtbase.qtPluginPrefix (
      with qt6Packages;
      [
        qtbase
        qtsvg
        qtpositioning
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [ qtwayland ]
    );
  };

  shellHook = ''
    echo "Ladybird development shell: 'ladybird-dev build' or 'ladybird-dev run'. The build goes to Build/nix."
  '';
}
