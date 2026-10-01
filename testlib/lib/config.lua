-- testlib/lib/config.lua
--
-- Per-machine configuration for the test harness. The file:
--
--   1. -c/--config <path> on nvme-check.lua (explicit; must exist)
--   2. $NVME_CONFIG (explicit; must exist)
--   3. <project>/config.user.lua (conventional; optional — copy
--      config.user.sample.lua for the annotated starting point)
--
-- The QEMU binary paths are required (there are no built-in defaults); the
-- build mode and the libvfn override are optional. Paths and the build mode
-- are the only tunables — selection is the runner's --where, build inputs are
-- build.zig.zon's.
--
-- `makac doctor nvmecheck` reports what was resolved, from where, and what
-- is missing.

local M = {}

local explicit_path = nil ---@type string?
local loaded = false
local cfg = nil ---@type table?

-- set_path(p) — nvme-check.lua's -c/--config; must run before anything
-- reads the configuration (i.e. before requiring the arch matrix).
---@param p string
function M.set_path(p)
	assert(not loaded, "config.set_path: configuration already loaded")
	assert(makac.fs.stat(p), ("config file does not exist: %s"):format(p))
	explicit_path = p
end

-- path() — the config file in effect, per the precedence above. The env var
-- is honored here so health/reporting sees the same file everything else does.
---@return string
function M.path()
	return explicit_path
		or os.getenv("NVME_CONFIG")
		or (PROJECT_DIR or ".") .. "/config.user.lua"
end

-- source() -> "flag -c/--config" | "env NVME_CONFIG" | "default location"
---@return string
function M.source()
	if explicit_path then return "flag -c/--config" end
	if os.getenv("NVME_CONFIG") then return "env NVME_CONFIG" end
	return "default location"
end

-- get() — the config table; {} when no file exists at the conventional path.
-- Raises with a clear message when a file exists but is malformed, or when an
-- explicitly-chosen file (flag/env) is missing.
---@return table
function M.get()
	if not loaded then
		local path = M.path()
		local st = makac.fs.stat(path)
		local result = {}
		if st and st.type == "file" then
			local chunk, err = loadfile(path)
			assert(chunk, ("config file %s: syntax error: %s"):format(path, tostring(err)))
			local ok, res = pcall(chunk)
			assert(ok, ("config file %s raised: %s"):format(path, tostring(res)))
			assert(type(res) == "table",
				("config file %s must return a table (see config.user.sample.lua)"):format(path))
			result = res
		elseif explicit_path or os.getenv("NVME_CONFIG") then
			error(("config file does not exist: %s"):format(path), 0)
		end
		cfg = result
		loaded = true
	end
	return cfg
end

-- qemu_bin(arch) -> string? — the configured qemu-system binary for an arch.
---@param arch string
---@return string?
function M.qemu_bin(arch)
	local q = M.get().qemu
	if type(q) ~= "table" then return nil end
	local a = q[arch]
	if type(a) ~= "table" then return nil end
	return a.bin
end

-- qemu_img() -> string? — the configured qemu-img binary.
---@return string?
function M.qemu_img()
	local q = M.get().qemu
	if type(q) ~= "table" then return nil end
	return q.img
end

-- build_nix() -> boolean? — explicit nix preference (true = always use
-- `nix develop`, false = never), nil = auto-detect (nix when available).
---@return boolean?
function M.build_nix()
	local b = M.get().build
	if type(b) ~= "table" then return nil end
	return b.nix
end

-- libvfn_src() -> string? — optional libvfn source-tree override (else the
-- pinned build.zig.zon dependency); passed to zig as -Dlibvfn-src.
---@return string?
function M.libvfn_src()
	local b = M.get().build
	if type(b) ~= "table" then return nil end
	return b.libvfn_src
end

-- ssh_pubkey() -> string — the public key authorized inside the guest by
-- cloud-init; a leading `~/` is expanded. Defaults to ~/.ssh/id_ed25519.pub
-- (the ssh-keygen default since OpenSSH 9.5).
---@return string
function M.ssh_pubkey()
	local s = M.get().ssh
	local p = (type(s) == "table") and s.pubkey or nil
	if type(p) ~= "string" or p == "" then
		p = "~/.ssh/id_ed25519.pub"
	end
	if p:sub(1, 2) == "~/" then
		p = (os.getenv("HOME") or "") .. p:sub(2)
	end
	return p
end

return M
