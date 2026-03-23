local M = {}

-- TODO: implement tree/body split logic
function M.init(args) end

-- TODO: implement toggle behavior
function M.toggle(args) end

-- TODO: return list of markup mode names matching arglead
function M.complete(arglead)
  return {}
end

function M.help()
  vim.cmd("help voom")
end

-- TODO: implement log buffer
function M.log_init() end

return M
