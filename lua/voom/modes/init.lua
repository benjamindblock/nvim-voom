-- Mode registry. Each markup mode is a Lua module under lua/voom/modes/
-- that implements the mode-specific heading detection and manipulation logic.
--
-- TODO: register individual mode modules here as they are ported from the
-- legacy Python implementation in legacy/autoload/voom/voom_vimplugin2657/.

local M = {}

-- Map of mode name -> loader function (lazy-loaded on first use).
M.modes = {}

-- Return the module for the named mode, or nil if unrecognized.
function M.get(name)
  local loader = M.modes[name]
  if loader then
    return loader()
  end
  return nil
end

return M
