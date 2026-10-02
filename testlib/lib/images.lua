-- testlib/lib/images.lua
-- Image specs shared by every nvme test: an empty raw disk (for NVMe
-- namespaces) and a cloud-init-customized Ubuntu LTS base image (the boot
-- disk). The arch-specific knobs (qemu binary, URL, sha256, customize VM
-- command line) come from the arch descriptor in arch.lua.

---@class ImgSpec
---@field name string
---@field builder string
---@field img_size? string
---@field format? string
---@field qemu_bin? string
---@field timeout_s? number
---@field verbose? boolean
---@field base_img? { url: string, sha256: string }
---@field env? table<string, string>
---@field env_hook? fun(env: table<string, string>): table<string, string>
---@field templates? { template: string, output: string }[]
---@field build_args? string[]

local M = {}

local config = require("./config")

-- qqmgr's fixed test password hash; the ssh key is the user's id_ed25519.
M.ROOT_PASSWORD_HASH =
"$6$rounds=4096$dZvpjkhL4EwsC3Wi$lJ8pB0hyROPYiWkCV0meWs9sqYTgiNnXxzBCn/XztnnwHBJVU11/0yRnsCrlpBKrH8k4xvlkVPbcPcqSt.tTL0"

--- Return designated SSH public key string, stripped of trailing whitespace.
---@return string
local function read_pubkey()
  local f = io.open(config.ssh_pubkey())
  if f then
    local s = (f:read("a"):gsub("%s+$", ""))
    f:close()
    return s
  end
  return ""
end

-- persisted per-arch instance id (a per-run id would invalidate the
-- cloud-init template/ISO stage on every re-run — see the e2e README)
---@param path string
---@return string
local function instance_id(path)
  local f = io.open(path)
  if f then
    local s = (f:read("a"):gsub("%s+$", ""))
    f:close()
    return s
  end
  local id = "nvme-" .. path:gsub("[^%w]", "-") .. "-" .. os.time()
  local dir = path:match("^(.*)/[^/]*$")
  if dir then makac.fs.mkdir_p(dir) end
  local wf = assert(io.open(path, "w"))
  wf:write(id .. "\n")
  wf:close()
  return id
end

-- raw(name, size, opts?) -> qemu:img spec for an empty disk.
-- format defaults to "raw" (that is the point for NVMe namespaces).
---@param name string
---@param size? string
---@param opts? { format?: string }
---@return ImgSpec
function M.raw(name, size, opts)
  opts = opts or {}
  return {
    name = name,
    builder = "raw",
    img_size = size or "1G",
    format = opts.format,
  }
end

-- cloud_init(arch) -> qemu:img spec. `arch` is the descriptor from arch.lua
-- and must provide: image_name, qemu_bin, base_url, base_sha256, hostname,
-- instance_id_file, build_args (and optionally img_size / img_timeout_s /
-- img_verbose).
---@param arch Arch
---@return ImgSpec
function M.cloud_init(arch)
  return {
    name = arch.image_name,
    builder = "cloud-init",
    qemu_bin = arch.qemu_bin,
    img_size = arch.img_size or "10G",
    timeout_s = arch.img_timeout_s or 2400,
    verbose = arch.img_verbose,

    base_img = { url = arch.base_url, sha256 = arch.base_sha256 },

    env = { hostname = arch.hostname },

    env_hook = function(env)
      env.ssh_public_key = read_pubkey()
      env.root_password_hash = M.ROOT_PASSWORD_HASH
      env.instance_id = instance_id(arch.instance_id_file)
      return env
    end,

    templates = {
      { template = "testlib/templates/user-data.tpl", output = "user-data" },
      { template = "testlib/templates/meta-data.tpl", output = "meta-data" },
    },

    build_args = arch.build_args,
  }
end

return M
