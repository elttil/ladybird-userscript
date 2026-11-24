# The header-only math functions of LLVM libc, installed like the llvm-libc vcpkg overlay port does.
# The LLVM commit and its hash are read from that port, so this follows whatever the source tree pins.
{
  lib,
  stdenvNoCC,
  fetchurl,
  overlayPorts,
}:

let
  port = "${overlayPorts}/llvm-libc";
  rev = (lib.importJSON "${port}/vcpkg.json").version-string;
  sha512 = lib.head (builtins.match ".*SHA512 ([0-9a-f]+).*" (builtins.readFile "${port}/portfile.cmake"));
in
stdenvNoCC.mkDerivation {
  pname = "llvm-libc-headers";
  version = "0-unstable-${lib.substring 0 12 rev}";

  src = fetchurl {
    url = "https://github.com/llvm/llvm-project/archive/${rev}.tar.gz";
    inherit sha512;
  };

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # The archive holds all of llvm-project, so only libc/ is extracted.
  installPhase = ''
    runHook preInstall

    tar xzf $src llvm-project-${rev}/libc
    cd llvm-project-${rev}/libc
    for directory in hdr include shared src/__support src/string/memory_utils; do
      find "$directory" -name '*.h' -exec install -Dm644 {} "$out/include/llvm-libc/{}" \;
    done
    install -Dm644 LICENSE.TXT $out/share/licenses/llvm-libc/LICENSE.TXT

    runHook postInstall
  '';

  meta = {
    description = "Header-only math functions of LLVM libc";
    homepage = "https://libc.llvm.org/";
    license = with lib.licenses; [
      asl20
      llvm-exception
    ];
  };
}
