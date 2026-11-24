{
  description = "Ladybird browser with userscript support";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Files that never affect the build, left out so that editing them does not trigger a rebuild.
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.difference ./. (
          lib.fileset.unions [
            ./flake.nix
            ./flake.lock
            ./nix
            ./Documentation
            ./.github
            ./README.md
            ./CONTRIBUTING.md
            ./CODE_OF_CONDUCT.md
            ./ISSUES.md
            ./SECURITY.md
          ]
        );
      };

      # Ladybird's patches and pins for its dependencies. Passed on their own, so that the dependencies they patch are
      # only rebuilt when these change, not on every change to the source tree.
      overlayPorts = lib.fileset.toSource {
        root = ./Meta/CMake/vcpkg/overlay-ports;
        fileset = ./Meta/CMake/vcpkg/overlay-ports;
      };

      version = "0-unstable-${builtins.substring 0 8 (self.lastModifiedDate or "19700101")}-${self.shortRev or "dirty"}";
    in
    {
      packages = forAllSystems (pkgs: {
        ladybird = pkgs.callPackage ./nix/package.nix {
          inherit src version overlayPorts;
          cargoLock = ./Cargo.lock;
        };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.ladybird;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/dev.nix {
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) ladybird;
        };
      });
    };
}
