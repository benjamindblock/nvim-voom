local T = MiniTest.new_set()

-- ==============================================================================
-- Module loading
-- ==============================================================================

T["loads without error"] = function()
  MiniTest.expect.no_error(function()
    require("voom")
  end)
end

-- ==============================================================================
-- Default configuration
-- ==============================================================================

T["config"] = MiniTest.new_set()

T["config"]["has default tree_width"] = function()
  local config = require("voom.config")
  MiniTest.expect.equality(config.defaults.tree_width, 30)
end

T["config"]["has default mode"] = function()
  local config = require("voom.config")
  MiniTest.expect.equality(config.defaults.default_mode, "markdown")
end

return T
