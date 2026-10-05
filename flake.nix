# SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
# SPDX-License-Identifier: BSD-2-Clause
{
  inputs = {
    # nixos-26.05 ships Zig 0.16.0
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    # Pinned makac: the orchestrator is provided to the dev shell from its own
    # flake (see jwdevantier/makac). Bump the commit here and re-lock to update.
    makac.url = "github:jwdevantier/makac/23eae101c47eb449ed2f2ccb5e5b020e71fefe74";
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
      devShells = forAllSystems ({ pkgs, system, ... }: {

        default = pkgs.mkShell {
          name = "nvme-check-dev";

          packages = (with pkgs; [
            zig

            gcc
            gnumake

            gdb

            cdrkit        # genisoimage
            qemu-utils    # qemu-img
          ]) ++ [
            makac.packages.${system}.makac
          ];

          # build.zig fetches the pinned libvfn fork itself (build.zig.zon).
          shellHook = ''
            echo "Zig:     $(zig version)"
            echo "makac:   $(makac --version)"
          '';
        };

        site = pkgs.mkShell {
          name = "nvme-check-site";
          packages = [ pkgs.mdbook ];
        };
      });
    };
}
