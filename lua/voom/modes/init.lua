-- Mode registry. Each markup mode is a Lua module under lua/voom/modes/
-- that implements the mode-specific heading detection and manipulation logic.
--
local M = {}

-- Map of mode name -> loader function (lazy-loaded on first use).
-- Each entry is added as its mode module is ported from the upstream Python
-- implementation (git submodule at legacy/autoload/voom/voom_vimplugin2657/).
M.modes = {
  markdown = function()
    return require("voom.modes.markdown")
  end,
  asciidoc = function()
    return require("voom.modes.asciidoc")
  end,
}

-- Return the module for the named mode, or nil if unrecognized.
function M.get(name)
  local loader = M.modes[name]
  if loader then
    return loader()
  end
  return nil
end

return M
