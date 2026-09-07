{
  lib,
  stdenv,
  fetchzip,
  linkFarm,
  zig_0_16,
  pkg-config,
  wayland-scanner,
  wayland,
  wayland-protocols,
  libxkbcommon,
}:

# The zig build sandbox has no network, so every build.zig.zon dependency is
# pre-fetched and linked in under the hash zig expects. Keep in sync with
# build.zig.zon: the `name` here must be that file's `.hash` string.
stdenv.mkDerivation (finalAttrs: {
  pname = "rill";
  version = "0.6.0-brill.2";

  src = lib.cleanSource ./.;

  deps = linkFarm "zig-packages" [
    {
      # `v0.4.8:protocol` is a git treeish — the tarball is just that subdir.
      name = "N-V-__8AAA3xAgD5Kwpwii8EK-ddKekNkv4zv8rJiDhDHLuI";
      path = fetchzip {
        url = "https://codeberg.org/river/river/archive/v0.4.8:protocol.tar.gz";
        hash = "sha256-KsgaDFg3lQGt53sCKXumYmWWfuH3iritU211fnuZkJQ=";
      };
    }
    {
      name = "wayland-0.6.0-lQa1kqz8AQADQmdNJsNhLoNHcnEGEUjrOaPV-dtEnEmX";
      path = fetchzip {
        url = "https://codeberg.org/ifreund/zig-wayland/archive/v0.6.0.tar.gz";
        hash = "sha256-3m/ITNhZUJ/5uD/Tqm+0uZSktGoYgWF5oldOqOCUkIE=";
      };
    }
    {
      name = "xkbcommon-0.4.0-VDqIe0i2AgDRsok2GpMFYJ8SVhQS10_PI2M_CnHXsJJZ";
      path = fetchzip {
        url = "https://codeberg.org/ifreund/zig-xkbcommon/archive/v0.4.0.tar.gz";
        hash = "sha256-zQkmP/cuhAtjOLqYS5D15khKzpqyhbyZ0TD6/8jOkqE=";
      };
    }
  ];

  nativeBuildInputs = [
    zig_0_16.hook
    pkg-config
    wayland-scanner
  ];

  buildInputs = [
    wayland
    wayland-protocols
    libxkbcommon
  ];

  dontConfigure = true;

  preBuild = ''
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
  '';

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "--release=safe"
  ];

  meta = {
    description = "Minimalist scrolling window manager for the river compositor";
    homepage = "https://github.com/OmarSiwy/Brill";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "rill";
  };
})
