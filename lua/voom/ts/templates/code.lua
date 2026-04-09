-- Shared no-op template for programming language modes.
--
-- Programming language outlines display structural elements (functions,
-- classes, methods) but do not support inserting new constructs via the
-- tree pane or normalising heading format — those operations require
-- language-aware code generation that is outside the scope of this plugin.
--
-- Move, cut, and sort are still available because they only rearrange body
-- lines without any format-aware mutations.

return {
  -- Inserting new code constructs through the tree pane is not supported.
  new_headline      = nil,

  -- No format normalisation for code after outline operations.
  do_body_after_oop = nil,

  capabilities = {
    insert  = false,  -- needs new_headline (generates code)
    promote = false,  -- needs do_body_after_oop (rewrites markers)
    demote  = false,  -- same as promote
    paste   = false,  -- needs new_headline for pasted nodes
    move    = true,   -- rearranges body lines only
    cut     = true,   -- rearranges body lines only
    sort    = true,   -- rearranges body lines only
  },
}
