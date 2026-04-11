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

-- Return the module for the named mode, or nil if unrecognized.
function M.get(name)
  local loader = M.modes[name]
  if loader then
    return loader()
  end
  return nil
end

return M
