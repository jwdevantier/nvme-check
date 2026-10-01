-- Project wiring for nvme-check.
--
-- This file is tracked even though `.makac/*` is otherwise gitignored: it is
-- the hand-written project file and lives BESIDE the data directory. It is the
-- project's dependency manifest -- think requirements.txt or package.json --
-- and `makac fetch` resolves it. Do not point it at a local checkout unless
-- you are developing the package itself.
--
-- Input keys are local labels. makac.qemu comes from Git, pinned to a
-- revision; this repo's own harness package is used in place.
return {
	inputs = {
		qemu = {
			fetcher = "fetchgit",
			with = {
				url = "https://github.com/jwdevantier/makac.qemu",
				rev = "47c670216db45b203e09b3f9b591ff413de9dc43",
			},
		},
		nvmecheck = {
			fetcher = "filesystem",
			with = { path = "testlib" },
		},
	},
	-- aliases are what workflows and packages use: 'qemu:img' in a step's
	-- uses field, require("pkgs/qemu/...") in Lua
	packages = { qemu = "qemu", nvmecheck = "nvmecheck" },
}
