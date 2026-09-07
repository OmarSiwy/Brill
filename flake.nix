{
  description = "Brill — minimalist scrolling window manager for river";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        rill = pkgs.callPackage ./package.nix { };
        default = rill;
      });

      overlays.default = final: prev: {
        rill = final.callPackage ./package.nix { };
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          # zig fetches the zon deps itself here; the package derivation
          # pins them instead because the sandbox has no network.
          packages = [
            pkgs.zig_0_16
            pkgs.pkg-config
            pkgs.wayland-scanner
            pkgs.wayland
            pkgs.wayland-protocols
            pkgs.libxkbcommon
          ];
        };
      });
    };
}
