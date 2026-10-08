# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
{
  inputs = {
    # nixos-26.05 ships Zig 0.16.0
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Pinned makac: the orchestrator is provided to the dev shell from its own
    # flake (see jwdevantier/makac). Bump the commit here and re-lock to update.
    makac.url = "github:jwdevantier/makac/685c70bb76396cc52a6b7913acf782d743ccf360";
  };

  outputs = { self, nixpkgs, makac }:
    let
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = fn:
        nixpkgs.lib.genAttrs allSystems
          (system: fn {
            pkgs = import nixpkgs { inherit system; };
            inherit system;
          });
    in
    {
      devShells = forAllSystems ({ pkgs, system, ... }:
        let
          # build.zig fetches the pinned libvfn fork itself (build.zig.zon).
          commonPackages = (with pkgs; [
            zig
            zls           # Zig language server: editor go-to-definition/hover

            gcc
            gnumake

            gdb

            cdrkit        # genisoimage
            qemu-utils    # qemu-img
          ]) ++ [
            makac.packages.${system}.makac
          ];

          mkDevShell = extraPackages: pkgs.mkShell {
            name = "nvme-check-dev";
            packages = commonPackages ++ extraPackages;
            shellHook = ''
              echo "Zig:     $(zig version)"
              echo "makac:   $(makac --version)"
            '';
          };
        in
        {
          default = mkDevShell [ ];

          site = pkgs.mkShell {
            name = "nvme-check-site";
            packages = [ pkgs.mdbook ];
          };
        });
    };
}
