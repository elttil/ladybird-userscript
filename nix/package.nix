# Based on the ladybird package in nixpkgs (pkgs/by-name/la/ladybird, MIT license),
# adapted to build the source tree of this repository instead of a pinned upstream commit.
{
  lib,
  stdenv,
  src,
  version,
  callPackage,
  apple-sdk_26,
  darwinMinVersionHook,
  cacert,
  fetchFromGitHub,
  pdfjs,
  chromium-hsts-preload-list,
  cmake,
  gitMinimal,
  ninja,
  pkg-config,
  curlFull, # Websocket support
  libavif,
  libicns,
  angle, # libEGL
  brotli,
  cpptrace,
  glib,
  glslang,
  harfbuzz,
  libdrm,
  libGL,
  libjpeg_turbo,
  libpng,
  libpsl,
  libxml2,
  libedit,
  libpulseaudio,
  libwebp,
  mimalloc,
  nghttp2,
  openssl,
  perl,
  python3,
  qt6Packages,
  woff2,
  wuffs,
  cargo,
  fast-float,
  ffmpeg,
  fontconfig,
  rustPlatform,
  rustc,
  rcodesign,
  makeWrapper,
  simdutf,
  skia,
  libtommath,
  sdl3,
  icu78,
  simdjson,
  sqlite,
  vulkan-headers,
  vulkan-loader,
  vulkan-memory-allocator,
  zlib,
  zmij,
}:

let
  overlayPorts = "${src}/Meta/CMake/vcpkg/overlay-ports";

  # Ladybird builds curl and nghttp2 with networking fixes of its own. Without the curl ones, RequestServer also goes
  # without CURLOPT_PIPEWAIT, which it only uses when curl defines LIBCURL_WAKES_ALL_PENDING_TRANSFERS.
  ladybirdNghttp2 = nghttp2.overrideAttrs (prev: {
    patches = (prev.patches or [ ]) ++ [
      "${overlayPorts}/nghttp2/ignore-connection-specific-response-fields.patch"
    ];
    # test_nghttp2_http_mandatory_headers expects the very headers this patch ignores to reset the stream.
    doCheck = false;
  });
  ladybirdCurl = (curlFull.override { nghttp2 = ladybirdNghttp2; }).overrideAttrs (prev: {
    patches = (prev.patches or [ ]) ++ [
      "${overlayPorts}/curl/wake-all-pending-transfers.patch"
      "${overlayPorts}/curl/poll-idle-connection-input.patch"
    ];
  });

  # Ladybird's own FFmpeg build carries patches that its decoders rely on. The symbol versioning patch (0100) is
  # left out: it only lets the bundled FFmpeg coexist with a system one, and the -ladybird names are undone below.
  ladybirdFFmpeg = ffmpeg.overrideAttrs (prev: {
    patches = (prev.patches or [ ]) ++ [
      "${overlayPorts}/ffmpeg/0101-vulkan-decode-dpb-distinct-no-drm-modifiers.patch"
      "${overlayPorts}/ffmpeg/0102-vulkan-av1-clear-unused-ref-frame-mvs.patch"
    ];
  });
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ladybird";
  inherit src version;

  cargoDeps = rustPlatform.importCargoLock {
    lockFile = "${finalAttrs.src}/Cargo.lock";
  };

  patches = lib.optionals stdenv.hostPlatform.isDarwin [
    # https://github.com/LadybirdBrowser/ladybird/issues/11891
    ./darwin-build.patch
  ];

  postPatch = ''
    sed -i '/iconutil/d' UI/CMakeLists.txt

    # https://github.com/LadybirdBrowser/ladybird/pull/12751
    # New Rust releases can deprecate APIs used by this snapshot.
    substituteInPlace Meta/CMake/rust_crate.cmake \
      --replace-fail 'set(RUSTC_TARGET_FLAGS -Dwarnings ' 'set(RUSTC_TARGET_FLAGS '

    # Upstream suffixes its reduced FFmpeg build to coexist with system FFmpeg.
    # Use nixpkgs' FFmpeg, which already provides the additional decoders.
    substituteInPlace Meta/CMake/check_for_dependencies.cmake \
      --replace-fail libavcodec-ladybird libavcodec \
      --replace-fail libavutil-ladybird libavutil \
      --replace-fail libswresample-ladybird libswresample

    perl -0pi -e \
      's/find_package\(ICU 78\.[0-9]+ EXACT REQUIRED COMPONENTS data i18n uc\)/find_package(ICU ${icu78.version} EXACT REQUIRED COMPONENTS data i18n uc)/ or die "ICU dependency not found\n"' \
      Meta/CMake/check_for_dependencies.cmake

    # Install the same PDF viewer assets and integration patch as the vcpkg build.
    # preConfigure points FindPDFJS.cmake at this copy.
    cp -r ${pdfjs}/share/pdf.js pdfjs
    chmod -R u+w pdfjs
    patch -d pdfjs -p1 < Meta/CMake/vcpkg/overlay-ports/pdfjs/0001-ladybird-embed.patch

    # Don't set absolute paths in RPATH
    substituteInPlace Meta/CMake/lagom_install_options.cmake \
      --replace-fail "\''${CMAKE_INSTALL_BINDIR}" "bin" \
      --replace-fail "\''${CMAKE_INSTALL_LIBDIR}" "lib"
  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    substituteInPlace Services/RequestServer/main.cpp \
      --replace-fail '@NIX_CA_BUNDLE@' '${cacert}/etc/ssl/certs/ca-bundle.crt'
  '';

  preConfigure = ''
    # HSTS preload data is the only remaining downloaded data cache.
    mkdir -p build/Caches
    cmakeFlagsArray+=("-DLADYBIRD_CACHE_DIR=$PWD/build/Caches")

    mkdir build/Caches/HSTSPreload
    cp ${chromium-hsts-preload-list}/share/chromium-hsts-preload-list/transport_security_state_static.json build/Caches/HSTSPreload

    cmakeFlagsArray+=("-DPDFJS_DIR=$PWD/pdfjs")
  '';

  nativeBuildInputs = [
    cargo
    cmake
    gitMinimal
    ninja
    perl
    pkg-config
    python3
    rustPlatform.cargoSetupHook
    rustc
    qt6Packages.wrapQtAppsHook
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ glslang ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    makeWrapper
    libicns
    rcodesign
  ];

  buildInputs = [
    ladybirdCurl
    brotli
    cpptrace
    fast-float
    ladybirdFFmpeg
    fontconfig
    harfbuzz
    libavif
    angle # libEGL
    libGL
    libjpeg_turbo
    libpng
    libpsl
    libtommath
    libxml2
    libedit
    libwebp
    (callPackage ./llvm-libc.nix { inherit src; })
    (mimalloc.overrideAttrs {
      # Ladybird uses heap APIs removed in mimalloc 3.
      version = "2.2.7";
      src = fetchFromGitHub {
        owner = "microsoft";
        repo = "mimalloc";
        tag = "v2.2.7";
        hash = "sha256-z9qMOTcGkURblZChXDGfQ58hrql52lG6EE1NQmxxuj0=";
      };
    })
    openssl
    qt6Packages.qtbase
    sdl3
    simdutf
    (skia.overrideAttrs (prev: {
      # Ladybird also uses Skia's color management API directly.
      gnFlags = prev.gnFlags ++ [
        "extra_cflags+=[\"-DSKCMS_DLL\"]"
      ];
      postInstall =
        (prev.postInstall or "")
        + lib.optionalString stdenv.hostPlatform.isDarwin ''
          # Ladybird's native font loader uses SkTypeface_Mac::MakeFromStream.
          install -Dm644 ../../src/ports/SkTypeface_mac_ct.h \
            $out/include/skia/src/ports/SkTypeface_mac_ct.h
          install -Dm644 ../../src/utils/mac/SkUniqueCFRef.h \
            $out/include/skia/src/utils/mac/SkUniqueCFRef.h
        '';
    }))
    wuffs
    woff2
    icu78
    simdjson
    sqlite
    zlib
    zmij
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    libpulseaudio.dev
    glib
    libdrm
    qt6Packages.qtpositioning
    qt6Packages.qtwayland
    vulkan-headers
    vulkan-loader
    vulkan-memory-allocator
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    apple-sdk_26
    (darwinMinVersionHook "14.0")
  ];

  cmakeFlags = [
    # Takes an enormous amount of resources, even with mold
    (lib.cmakeBool "ENABLE_LTO_FOR_RELEASE" false)
    # Disable network operations
    "-DENABLE_NETWORK_DOWNLOADS=OFF"
    # Ladybird requires icu 78, but without this flag the default icu
    # from other dependencies gets picked up instead.
    (lib.cmakeFeature "ICU_ROOT" (toString icu78.dev))
    # Upstream defaults to -march=native and -Ctarget-cpu=native, which cc-wrapper
    # cannot strip for Rust; target a portable baseline instead.
    (lib.cmakeBool "LADYBIRD_BASELINE_CPU_TARGET" true)
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    "-DCMAKE_INSTALL_LIBEXECDIR=libexec"
  ];

  # ld: [...]/OESVertexArrayObject.cpp.o: undefined reference to symbol 'glIsVertexArrayOES'
  # ld: [...]/libGL.so.1: error adding symbols: DSO missing from command line
  # https://github.com/LadybirdBrowser/ladybird/issues/371#issuecomment-2616415434
  env.NIX_LDFLAGS = lib.optionalString stdenv.hostPlatform.isLinux "-lGL " + "-lfontconfig";

  postInstall = lib.optionalString stdenv.hostPlatform.isDarwin ''
    mkdir -p $out/Applications $out/bin
    mv $out/bundle/Ladybird.app $out/Applications
    png2icns "$out/Applications/Ladybird.app/Contents/Resources/app_icon.icns" \
      ${finalAttrs.src}/UI/Icons/macos/app_icon.iconset/icon_{16x16,32x32,128x128,256x256,512x512,512x512@2x}.png
    makeWrapper "$out/Applications/Ladybird.app/Contents/MacOS/Ladybird" "$out/bin/Ladybird"
  '';

  # Sign the complete bundle after stripping and other fixups, preserving entitlements.
  postFixup = lib.optionalString stdenv.hostPlatform.isDarwin ''
    rcodesign sign \
      --entitlements-xml-file ${finalAttrs.src}/Meta/Entitlements.plist \
      "$out/Applications/Ladybird.app"
  '';

  # Only Ladybird and WebContent need wrapped, if Qt is enabled.
  # On linux we end up wrapping some non-Qt apps, like headless-browser.
  dontWrapQtApps = stdenv.hostPlatform.isDarwin;

  meta = {
    description = "Ladybird browser with userscript support";
    homepage = "https://github.com/elttil/ladybird-userscript";
    license = lib.licenses.bsd2;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
    mainProgram = "Ladybird";
  };
})
