-- Minimal Neovim config for running tests in CI and locally.
-- Adds only what is needed: mini.nvim for the MiniTest harness, and the
-- plugin under test. This file is intentionally kept small so that test
-- results reflect the plugin's behavior in a near-stock Neovim environment.

-- Bootstrap mini.nvim (provides MiniTest) on first run by cloning it into
-- Neovim's data directory. Subsequent runs reuse the cached clone.
local mini_path = vim.fn.stdpath("data") .. "/site/pack/deps/start/mini.nvim"
if not vim.loop.fs_stat(mini_path) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/echasnovski/mini.nvim",
    mini_path,
  })
end
vim.opt.rtp:prepend(mini_path)

-- Load mini.test and expose MiniTest as a global so test files can call
-- MiniTest.new_set() and MiniTest.run() without a local require.
-- Configure find_files to discover spec files under test/spec/ so that
-- MiniTest.run() with no arguments works correctly from the repo root.
require("mini.test").setup({
  collect = {
    find_files = function()
      return vim.fn.glob("test/spec/*_spec.lua", false, true)
    end,
  },
})

-- Add the plugin under test to the runtimepath so that `require("voom")`
-- and `runtime plugin/voom.lua` resolve correctly from the repo root.
vim.opt.rtp:prepend(vim.fn.getcwd())

-- Source the plugin entry point so all user commands are registered before
-- any test file runs.
vim.cmd("runtime plugin/voom.lua")
