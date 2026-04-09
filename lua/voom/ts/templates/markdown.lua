-- Markdown editing template for the Treesitter-backed mode.
--
-- Contains the format-aware editing operations extracted verbatim from
-- lua/voom/modes/markdown.lua.  The logic is identical; only the file it
-- lives in has changed.  See that file for full inline documentation.
--
-- Exported symbols:
--   new_headline(outline_state, level, preceding_line) -> { tree_head, body_lines }
--   do_body_after_oop(...)                             -> b_delta
--   capabilities                                       -> table

local M = {}

-- Maps heading level (int) -> underline character for setext-style headings.
M.LEVELS_ADS = { [1] = "=", [2] = "-" }

-- Maps underline character -> heading level (inverse of LEVELS_ADS).
M.ADS_LEVELS = { ["="] = 1, ["-"] = 2 }

-- ==============================================================================
-- Private helpers
-- ==============================================================================

local function is_adornment(s)
  if s == "" then
    return false
  end
  local ch = s:sub(1, 1)
  if ch ~= "=" and ch ~= "-" then
    return false
  end
  return s:match("^" .. ch .. "+$") ~= nil
end

local function strip(s)
  return s:match("^%s*(.-)%s*$")
end

local function update_bnodes(bnodes, tlnum, delta)
  for i = tlnum, #bnodes do
    bnodes[i] = bnodes[i] + delta
  end
end

-- ==============================================================================
-- new_headline
-- ==============================================================================

function M.new_headline(outline_state, level, preceding_line)
  local tree_head = "NewHeadline"
  local body_lines

  if level < 3 and not outline_state.use_hash then
    body_lines = { tree_head, M.LEVELS_ADS[level]:rep(11), "" }
  else
    local hashes = string.rep("#", level)
    if outline_state.use_close_hash then
      body_lines = { hashes .. " " .. tree_head .. " " .. hashes, "" }
    else
      body_lines = { hashes .. " " .. tree_head, "" }
    end
  end

  if preceding_line ~= nil and preceding_line:match("%S") then
    table.insert(body_lines, 1, "")
  end

  return { tree_head = tree_head, body_lines = body_lines }
end

-- ==============================================================================
-- do_body_after_oop
-- ==============================================================================

function M.do_body_after_oop(lines, bnodes, levels, outline_state,
                              oop, lev_delta,
                              blnum1, tlnum1, blnum2, tlnum2,
                              blnum_cut, tlnum_cut)
  local Z       = #lines
  local b_delta = 0

  if (oop == "cut" or oop == "up")
      and blnum_cut > 0 and blnum_cut < Z
      and lines[blnum_cut]:match("%S") then
    table.insert(lines, blnum_cut + 1, "")
    update_bnodes(bnodes, tlnum_cut + 1, 1)
    b_delta = b_delta + 1
  end

  if oop == "cut" then
    return b_delta
  end

  if blnum2 < Z and lines[blnum2]:match("%S") then
    table.insert(lines, blnum2 + 1, "")
    update_bnodes(bnodes, tlnum2 + 1, 1)
    b_delta = b_delta + 1
  end

  if lev_delta ~= 0 or oop == "paste" then
    for i = tlnum2, tlnum1, -1 do
      local lev  = levels[i]
      local lev_ = lev - lev_delta

      local bln = bnodes[i]
      local L1  = lines[bln]:gsub("%s+$", "")
      local L2  = (bln < #lines) and lines[bln + 1]:gsub("%s+$", "") or ""

      local has_hash       = true
      local has_close_hash = outline_state.use_close_hash
      if is_adornment(L2) then
        has_hash = false
      else
        has_close_hash = L1:sub(-1) == "#"
      end

      local use_hash, use_close_hash
      if oop == "paste" then
        if lev > 2 then
          use_hash = true
        else
          use_hash = outline_state.use_hash
        end
        use_close_hash = outline_state.use_close_hash
      elseif lev < 3 and lev_ < 3 then
        use_hash       = has_hash
        use_close_hash = has_close_hash
      elseif lev > 2 and lev_ > 2 then
        use_hash       = true
        use_close_hash = has_close_hash
      elseif lev < 3 and lev_ > 2 then
        use_hash       = outline_state.use_hash
        use_close_hash = outline_state.use_close_hash
      else
        use_hash       = true
        use_close_hash = has_close_hash
      end

      if not use_hash and not has_hash then
        if lev_delta == 0 then goto next_heading end
        -- TODO: use vim.fn.strchars(L2) for Unicode-aware adornment width.
        lines[bln + 1] = M.LEVELS_ADS[lev]:rep(#L2)

      elseif use_hash and has_hash then
        local inner_both = L1:gsub("^#+", ""):gsub("#+$", "")
        local inner_left = L1:match("^#+(.*)")

        if use_close_hash and has_close_hash then
          if lev_delta == 0 then goto next_heading end
          lines[bln] = string.rep("#", lev) .. inner_both .. string.rep("#", lev)
        elseif not use_close_hash and not has_close_hash then
          if lev_delta == 0 then goto next_heading end
          lines[bln] = string.rep("#", lev) .. inner_left
        elseif use_close_hash and not has_close_hash then
          local inner = inner_both:gsub("%s*$", "")
          lines[bln] = string.rep("#", lev) .. inner .. " " .. string.rep("#", lev)
        else
          local inner = inner_both:gsub("%s*$", "")
          lines[bln] = string.rep("#", lev) .. inner
        end

      elseif not use_hash and has_hash then
        local title = strip(L1:gsub("^#+", ""):gsub("#+$", ""))
        lines[bln] = title
        -- TODO: use vim.fn.strchars(title) for Unicode-aware adornment width.
        table.insert(lines, bln + 1, M.LEVELS_ADS[lev]:rep(#title))
        update_bnodes(bnodes, i + 1, 1)
        b_delta = b_delta + 1

      else
        local sp = L1:sub(1, 1):match("%s") and "" or " "
        if use_close_hash then
          lines[bln] = string.rep("#", lev) .. sp .. L1 .. " " .. string.rep("#", lev)
        else
          lines[bln] = string.rep("#", lev) .. sp .. L1
        end

        local L3 = (bln + 1 < #lines) and lines[bln + 2]:gsub("%s+$", "") or ""
        if is_adornment(L3) then
          lines[bln + 1] = ""
        else
          table.remove(lines, bln + 1)
          update_bnodes(bnodes, i + 1, -1)
          b_delta = b_delta - 1
        end
      end

      ::next_heading::
    end
  end

  blnum1 = bnodes[tlnum1]
  if blnum1 > 1 and lines[blnum1 - 1]:match("%S") then
    table.insert(lines, blnum1, "")
    update_bnodes(bnodes, tlnum1, 1)
    b_delta = b_delta + 1
  end

  if oop == "down"
      and blnum_cut > 0 and blnum_cut < Z
      and lines[blnum_cut]:match("%S") then
    table.insert(lines, blnum_cut + 1, "")
    update_bnodes(bnodes, tlnum_cut + 1, 1)
    b_delta = b_delta + 1
  end

  assert(#lines == Z + b_delta,
    "do_body_after_oop: line count mismatch (got " .. #lines ..
    ", expected " .. (Z + b_delta) .. ")")
  return b_delta
end

-- ==============================================================================
-- Capabilities
-- ==============================================================================

M.capabilities = {
  insert  = true,
  promote = true,
  demote  = true,
  move    = true,
  cut     = true,
  paste   = true,
  sort    = true,
}

return M
