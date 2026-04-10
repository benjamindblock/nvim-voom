local H = dofile("test/helpers.lua")

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
  MiniTest.expect.equality(config.defaults.tree_width, 40)
end

T["config"]["has default mode"] = function()
  local config = require("voom.config")
  MiniTest.expect.equality(config.defaults.default_mode, "markdown")
end

T["config"]["setup() is exposed on public API"] = function()
  local voom = require("voom")
  MiniTest.expect.equality(type(voom.setup), "function")
end

T["config"]["setup() merges user opts into config.options"] = function()
  local voom   = require("voom")
  local config = require("voom.config")
  voom.setup({ tree_width = 55 })
  MiniTest.expect.equality(config.options.tree_width, 55)
  -- Restore defaults so other tests are unaffected.
  voom.setup({})
end

-- ==============================================================================
-- complete()
-- ==============================================================================

T["complete"] = MiniTest.new_set()

T["complete"]["empty arglead returns all modes"] = function()
  local voom = require("voom")
  local result = voom.complete("")
  MiniTest.expect.equality(type(result), "table")
  -- "markdown" must be present.
  local has_markdown = false
  for _, v in ipairs(result) do
    if v == "markdown" then
      has_markdown = true
    end
  end
  MiniTest.expect.equality(has_markdown, true)
end

T["complete"]["matching prefix returns matching modes"] = function()
  local voom = require("voom")
  local result = voom.complete("mar")
  MiniTest.expect.equality(#result, 1)
  MiniTest.expect.equality(result[1], "markdown")
end

T["complete"]["asciidoc is absent from completion list"] = function()
  local voom = require("voom")
  local result = voom.complete("")
  local has_asciidoc = false
  for _, v in ipairs(result) do
    if v == "asciidoc" then
      has_asciidoc = true
    end
  end
  MiniTest.expect.equality(has_asciidoc, false)
end

T["complete"]["asc prefix returns no matches"] = function()
  local voom = require("voom")
  local result = voom.complete("asc")
  MiniTest.expect.equality(#result, 0)
end

T["complete"]["non-matching prefix returns empty list"] = function()
  local voom = require("voom")
  local result = voom.complete("xyz")
  MiniTest.expect.equality(#result, 0)
end

-- ==============================================================================
-- init() and toggle()
-- ==============================================================================

T["init"] = MiniTest.new_set({
  hooks = {
    post_case = H.cleanup_registered_bodies,
  },
})

T["init"]["creates a tree window for a markdown buffer"] = function()
  local voom = require("voom")
  local state = require("voom.state")

  local body = vim.api.nvim_create_buf(false, true)
  T["init"]._body_buf = body
  vim.api.nvim_buf_set_name(body, "init_test.md")
  vim.api.nvim_buf_set_lines(body, 0, -1, false, { "# Hello", "## World" })

  -- Open the body buffer in the current window, then call init().
  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"
  voom.init("markdown")

  MiniTest.expect.equality(state.is_body(body), true)
  local tree_buf = state.get_tree(body)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), true)
end

T["init"]["rejects explicit asciidoc mode"] = function()
  local voom = require("voom")
  local state = require("voom.state")

  local body = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(body, "init_test.adoc")
  vim.api.nvim_buf_set_lines(body, 0, -1, false, { "= Hello", "== World" })

  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "asciidoc"
  local notifications = H.with_captured_notify(function()
    voom.init("asciidoc")
  end)

  MiniTest.expect.equality(state.is_body(body), false)
  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(notifications[1].msg:find("unsupported mode 'asciidoc'", 1, true) ~= nil, true)
end

T["init"]["rejects asciidoc filetype auto-detection"] = function()
  local voom = require("voom")
  local state = require("voom.state")

  local body = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(body, "ft_detect.adoc")
  vim.api.nvim_buf_set_lines(body, 0, -1, false, { "= Title" })

  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "asciidoc"
  local notifications = H.with_captured_notify(function()
    voom.init()
  end)

  MiniTest.expect.equality(state.is_body(body), false)
  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(notifications[1].msg:find("unsupported mode 'asciidoc'", 1, true) ~= nil, true)
end

T["init"]["rejects asciidoctor filetype auto-detection"] = function()
  local voom = require("voom")
  local state = require("voom.state")

  local body = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(body, "ft_asciidoctor.adoc")
  vim.api.nvim_buf_set_lines(body, 0, -1, false, { "= Title" })

  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "asciidoctor"
  local notifications = H.with_captured_notify(function()
    voom.init()
  end)

  MiniTest.expect.equality(state.is_body(body), false)
  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(notifications[1].msg:find("unsupported mode 'asciidoctor'", 1, true) ~= nil, true)
end

T["toggle"] = MiniTest.new_set()

T["toggle"]["closes tree when body already has one"] = function()
  local voom = require("voom")
  local state = require("voom.state")
  local tree_mod = require("voom.tree")

  local body = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(body, "toggle_test.md")
  vim.api.nvim_buf_set_lines(body, 0, -1, false, { "# Heading" })

  -- Open body and create a tree.
  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"
  local tree_buf = tree_mod.create(body, "markdown")
  MiniTest.expect.equality(state.is_body(body), true)

  -- Toggle should close the tree.
  vim.api.nvim_set_current_buf(body)
  voom.toggle("markdown")

  MiniTest.expect.equality(state.is_body(body), false)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(tree_buf), false)

  if vim.api.nvim_buf_is_valid(body) then
    vim.api.nvim_buf_delete(body, { force = true })
  end
end

T["toggle"]["opens tree when body has none"] = function()
  local voom = require("voom")
  local state = require("voom.state")

  local body = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(body, "toggle_open_test.md")
  vim.api.nvim_buf_set_lines(body, 0, -1, false, { "# Open Me" })

  vim.api.nvim_set_current_buf(body)
  vim.bo[body].filetype = "markdown"
  voom.toggle("markdown")

  MiniTest.expect.equality(state.is_body(body), true)

  -- Clean up.
  require("voom.tree").close(body)
  if vim.api.nvim_buf_is_valid(body) then
    vim.api.nvim_buf_delete(body, { force = true })
  end
end

-- ==============================================================================
-- grep()
-- ==============================================================================

T["grep"] = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.cleanup_registered_bodies()
      vim.fn.setqflist({}, "r")
    end,
  },
})

T["grep"]["populates quickfix with matching headings and body lines"] = function()
  local voom = require("voom")
  local tree = require("voom.tree")

  local body = H.make_scratch_buf({
    "# Alpha",
    "",
    "## Beta",
    "",
    "# Gamma",
  }, "grep_matches.md")
  T["grep"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  local tree_buf = tree.create(body, "markdown")
  vim.api.nvim_set_current_buf(tree_buf)

  local notifications = H.with_captured_notify(function()
    voom.grep("a")
  end)

  local qf = vim.fn.getqflist()
  MiniTest.expect.equality(#notifications, 0)
  MiniTest.expect.equality(#qf, 3)
  MiniTest.expect.equality(qf[1].lnum, 1)
  MiniTest.expect.equality(qf[1].text, "Alpha")
  MiniTest.expect.equality(qf[2].lnum, 3)
  MiniTest.expect.equality(qf[2].text, "Beta")
  MiniTest.expect.equality(qf[3].lnum, 5)
  MiniTest.expect.equality(qf[3].text, "Gamma")
end

T["grep"]["warns on no matches and leaves quickfix empty"] = function()
  local voom = require("voom")
  local tree = require("voom.tree")

  local body = H.make_scratch_buf({
    "# Alpha",
    "",
    "## Beta",
  }, "grep_nomatch.md")
  T["grep"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  tree.create(body, "markdown")

  local notifications = H.with_captured_notify(function()
    voom.grep("Z+")
  end)

  local qf = vim.fn.getqflist()
  MiniTest.expect.equality(#qf, 0)
  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(notifications[1].level, vim.log.levels.WARN)
  MiniTest.expect.equality(notifications[1].msg, "VOoM grep: no headings matched 'Z+'")
end

-- ==============================================================================
-- voominfo()
-- ==============================================================================

T["voominfo"] = MiniTest.new_set({
  hooks = H.clean_hooks(),
})

T["voominfo"]["reports mode node count selected line and heading text"] = function()
  local voom = require("voom")
  local tree = require("voom.tree")
  local state = require("voom.state")

  local body = H.make_scratch_buf({
    "# Alpha",
    "",
    "## Beta",
  }, "voominfo_ok.md")
  T["voominfo"]._body_buf = body

  vim.api.nvim_set_current_buf(body)
  tree.create(body, "markdown")
  state.set_snLn(body, 2)

  local notifications = H.with_captured_notify(function()
    voom.voominfo()
  end)

  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(notifications[1].level, vim.log.levels.INFO)
  MiniTest.expect.equality(notifications[1].msg:find("mode:%s+markdown") ~= nil, true)
  MiniTest.expect.equality(notifications[1].msg:find("nodes:%s+2") ~= nil, true)
  MiniTest.expect.equality(notifications[1].msg:find("snLn:%s+2") ~= nil, true)
  MiniTest.expect.equality(notifications[1].msg:find("node:%s+Beta") ~= nil, true)
end

T["voominfo"]["errors when current buffer has no active VOoM tree"] = function()
  local voom = require("voom")
  local buf = H.make_scratch_buf({ "plain text" }, "voominfo_error.txt")

  vim.api.nvim_set_current_buf(buf)
  local notifications = H.with_captured_notify(function()
    voom.voominfo()
  end)

  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(notifications[1].level, vim.log.levels.ERROR)
  MiniTest.expect.equality(notifications[1].msg, "VOoM: current buffer has no active VOoM tree")

  H.del_buf(buf)
end

return T
