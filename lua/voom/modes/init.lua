-- Mode registry. Maps mode names to lazy-loaded Treesitter-backed mode
-- modules.  Adding a new language only requires a query file under
-- lua/voom/ts/queries/ — the build_mode factory assembles the rest.

local M = {}

-- Map of mode name -> loader function (lazy-loaded on first use).
M.modes = {
  markdown   = function() return require("voom.ts").build_mode("markdown") end,
  python     = function() return require("voom.ts").build_mode("python") end,
  lua        = function() return require("voom.ts").build_mode("lua") end,
  ruby       = function() return require("voom.ts").build_mode("ruby") end,
  go         = function() return require("voom.ts").build_mode("go") end,
  javascript = function() return require("voom.ts").build_mode("javascript") end,
  typescript = function() return require("voom.ts").build_mode("typescript") end,
  tsx        = function() return require("voom.ts").build_mode("tsx") end,
  bash       = function() return require("voom.ts").build_mode("bash") end,
  html       = function() return require("voom.ts").build_mode("html") end,
}

-- Neovim &filetype values that don't match our mode names verbatim.
-- Kept alongside the mode registry so new modes and their aliases live in
-- one place.
local FILETYPE_ALIASES = {
  md               = "markdown",
  sh               = "bash",
  javascriptreact  = "javascript",
  typescriptreact  = "tsx",
}

-- Return the module for the named mode, or nil if unrecognized.
function M.get(name)
  local loader = M.modes[name]
  if loader then
    return loader()
  end
  return nil
end

-- Map a Vim &filetype to a registered mode name, or nil if voom does not
-- support the filetype.  Applies the alias table first so that e.g. "md"
-- resolves to "markdown".
function M.resolve_filetype(ft)
  local mode = FILETYPE_ALIASES[ft] or ft
  if M.modes[mode] then
    return mode
  end
  return nil
end

return M
