-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
-- nvmecheck health check (makac's design/doctor.md): the per-machine
-- configuration (config.user.lua), resolved QEMU binaries, the batch-build
-- toolchain, and a self-check that the library modules load.

-- config.user.lua problems are reported by the configuration section below
-- rather than blowing up module load; everything config-dependent is pcall'd.

local config = require("pkgs/nvmecheck/config")

return function(health, pkg_name)
	local function on_path(bin)
		local ok, res = pcall(makac.exec, { "sh", "-c", "command -v " .. bin })
		if ok and res.code == 0 then
			local p = (res.stdout or ""):gsub("%s+$", "")
			if p ~= "" then return p end
		end
		return nil
	end

	-- Config accessors can raise on a malformed file (reported in the
	-- configuration section); here an unreadable config counts as "unset".
	local function cfg(fn, ...)
		local ok, v = pcall(fn, ...)
		return ok and v or nil
	end

	health.start("configuration")
	local cfg_ok, cfg_err = pcall(config.get)
	if makac.fs.stat(config.path()) then
		if cfg_ok then
			health.ok(("config loaded: %s (%s)"):format(config.path(), config.source()))
		else
			health.error(("config file %s is malformed"):format(config.path()), tostring(cfg_err))
		end
	elseif config.source() ~= "default location" then
		health.error(("config file chosen via %s does not exist: %s")
			:format(config.source(), config.path()), "fix the path or unset it")
	else
		health.error("no config.user.lua — the QEMU binaries are not configured",
			"copy config.user.sample.lua to config.user.lua and set qemu.<arch>.bin")
	end

	-- archlib evaluates the QEMU paths at load; a malformed config raises there
	local arch_ok, archlib_or_err = pcall(require, pkg_name .. "/arch")
	local archlib = arch_ok and archlib_or_err or nil

	health.start("qemu binaries (qemu-system + qemu-img)")
	if not archlib then
		health.error("arch matrix failed to load", tostring(archlib_or_err))
	else
		-- The QEMU binaries are required per machine; there are no defaults.
		for _, name in ipairs(archlib.names) do
			local key = ("qemu.%s.bin"):format(name)
			local bin = cfg(config.qemu_bin, name)
			if type(bin) ~= "string" then
				health.error(("%s is not set"):format(key),
					"set it in config.user.lua (copy config.user.sample.lua)")
			elseif makac.fs.stat(bin) then
				health.ok(("%s: %s"):format(name, bin))
			else
				health.error(("%s: %s does not exist"):format(name, bin),
					("fix %s in config.user.lua"):format(key))
			end
		end
		-- qemu-img is invoked by name (by the qemu:img builder and the
		-- snapshot probe alike); what matters is what PATH resolves.
		local img = on_path("qemu-img")
		if img then
			health.ok("qemu-img (from PATH): " .. img)
		else
			health.error("qemu-img not found on PATH",
				"put the QEMU build to test on PATH (qemu:img invokes qemu-img by name)")
		end
	end

	health.start("guest ssh key")
	local pubkey = cfg(config.ssh_pubkey)
	if type(pubkey) ~= "string" or pubkey == "" then
		health.error("no SSH public key configured", "set ssh.pubkey in config.user.lua")
	elseif makac.fs.stat(pubkey) then
		health.ok("ssh public key: " .. pubkey)
	else
		health.error(("ssh public key not found: %s"):format(pubkey),
			"generate one with ssh-keygen, or set ssh.pubkey in config.user.lua")
	end

	health.start("batch build toolchain")
	local want_ok, want_nix = pcall(config.build_nix)
	if not want_ok then want_nix = nil end -- malformed config already reported above
	local nix_path = on_path("nix")
	local zig_path = on_path("zig")
	if want_nix == false then
		health.info("build.nix = false: batches build with the ambient zig on PATH")
		if zig_path then
			health.ok("zig found at " .. zig_path)
		else
			health.error("zig not found on PATH", "install zig (see build.zig.zon minimum_zig_version)")
		end
	elseif want_nix == true then
		if nix_path then
			health.ok("build.nix = true: batches build via `nix develop` (" .. nix_path .. ")")
		else
			health.error("build.nix = true but nix is not on PATH",
				"install nix, or set build.nix = false in config.user.lua")
		end
	else
		if nix_path then
			health.ok("auto: nix found — batches build via `nix develop` (flake-pinned zig)")
		elseif zig_path then
			health.ok("auto: no nix — batches build with the ambient zig (" .. zig_path .. ")")
		else
			health.error("neither nix nor zig found on PATH",
				"install nix (flakes) or a zig toolchain matching build.zig.zon")
		end
	end

	health.start("library")
	for _, mod in ipairs({ "arch", "images", "guest", "nvme", "selection", "base", "libvfn_simple", "zigtest", "tagexpr", "config" }) do
		local ok, err = pcall(require, pkg_name .. "/" .. mod)
		if ok then
			health.ok("require " .. pkg_name .. "/" .. mod)
		else
			health.error("require " .. pkg_name .. "/" .. mod, tostring(err))
		end
	end
end
