-- config.user.sample.lua — per-machine configuration for nvme-check.
--
-- Copy to config.user.lua (gitignored) and edit. The QEMU paths are
-- required; the `build` keys are optional.
--
-- Which file is read, in precedence order:
--   nvme-check.lua -c/--config <path>  >  $NVME_CONFIG  >  ./config.user.lua
--
-- Inspect what makac resolved — and what is still missing:
--   makac doctor nvmecheck

return {
	qemu = {
		-- Required: there are no built-in defaults. Point these at the QEMU
		-- build you want to test. `makac doctor nvmecheck` checks that they
		-- exist.
		img = "/opt/qemu/bin/qemu-img",
		amd64 = { bin = "/opt/qemu/bin/qemu-system-x86_64" },
		s390x = { bin = "/opt/qemu/bin/qemu-system-s390x" },
	},

	ssh = {
		-- Public key authorized inside the guest for the harness's SSH
		-- connection. Defaults to ~/.ssh/id_ed25519.pub (the ssh-keygen
		-- default since OpenSSH 9.5). The matching private key must be
		-- usable by ssh on this host.
		-- pubkey = "~/.ssh/id_ed25519.pub",
	},

	build = {
		-- true:  always build batches via `nix develop` (flake-pinned zig).
		-- false: build with the ambient zig on PATH.
		-- unset: auto — nix when available, ambient zig when not.
		-- nix = false,

		-- libvfn source-tree override (upstream + your patches); otherwise
		-- the pinned build.zig.zon dependency is used.
		-- libvfn_src = "/home/me/repos/libvfn",
	},
}
