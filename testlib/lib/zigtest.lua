-- testlib/lib/zigtest.lua
-- The `nvmecheck:build` action: cross-compile one Zig test root (a batch's
-- `program`) for a guest arch and return the resulting binary path.
--
-- This owns the build.zig interface (`-Dprogram=...`); workflows never see it.

local config = require("./config")

local M = {}

-- guest arch -> zig target triple (static musl; no in-guest libvfn needed)
local ZIG_TARGET = {
	amd64 = "x86_64-linux-musl",
	s390x = "s390x-linux-musl",
}

---@param s string
---@return string
local function sanitize(s)
	return (tostring(s):gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""))
end

---@param s string
---@return string
local function shquote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- build(with) -> { changed?, err?, out = { path, name } }
-- with = { arch, program, name?, host?, libvfn_src? }   (libvfn_src overrides the pinned zon dep)
--   host=true builds for the host (no -Dtarget/-Dstatic); the default
--   cross-compiles a static binary for the guest arch.
---@param with table
---@return table
function M.build(with)
	assert(type(with) == "table", "nvmecheck:build: 'with' table is required")
	local arch = assert(with.arch, "nvmecheck:build: 'arch' is required")
	local program = assert(with.program, "nvmecheck:build: 'program' is required")
	assert(ZIG_TARGET[arch], "nvmecheck:build: unknown arch '" .. tostring(arch) .. "'")

	local name = sanitize(with.name or program)
	local triple = ZIG_TARGET[arch]
	local repo = tostring(makac.fs.cwd():path())
	local prefix = "/tmp/nvmecheck-build-" .. arch .. (with.host and "-host-" or "-") .. name

	local argv = {
		"zig", "build",
		"-Dprogram=" .. program,
		"-Dprogram-name=" .. name,
		"--prefix", prefix,
	}
	if not with.host then
		table.insert(argv, 3, "-Dstatic=true")
		table.insert(argv, 3, "-Dtarget=" .. triple)
	end
	if with.libvfn_src or config.libvfn_src() then
		argv[#argv + 1] = "-Dlibvfn-src=" .. (with.libvfn_src or config.libvfn_src())
	end

	local words = {}
	for _, a in ipairs(argv) do words[#words + 1] = shquote(a) end
	local script = "cd " .. shquote(repo) .. " && " .. table.concat(words, " ")

	-- Building batches: config.user.lua's build.nix decides between the
	-- flake-pinned zig (true) and the ambient zig on PATH (false);
	-- unset: auto-detect — nix when available, ambient zig when not.
	local want_nix = config.build_nix()
	local have_nix = makac.exec({ "sh", "-c", "command -v nix >/dev/null 2>&1" }).code == 0
	if want_nix == true and not have_nix then
		return { err = "config.user.lua sets build.nix = true, but nix is not on PATH" }
	end
	local use_nix = (want_nix ~= nil) and want_nix or have_nix
	local cmd = use_nix
		and { "nix", "develop", repo, "-c", "sh", "-c", script }
		or { "sh", "-c", script }
	local r = makac.exec(cmd)
	if r.code ~= 0 then
		return { err = ("zig build failed (%d)\nstdout:\n%s\nstderr:\n%s")
			:format(r.code, r.stdout or "", r.stderr or "") }
	end

	local path = prefix .. "/bin/" .. name
	if not makac.fs.stat(path) then
		return { err = "zig build produced no " .. path }
	end
	return { changed = true, out = { path = path, name = name } }
end

return M
