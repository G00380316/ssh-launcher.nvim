---@mod ssh_launcher.ui.render Chunked line rendering
---
--- Views describe lines as `{ {text, highlight}, ... }` and this module turns
--- them into buffer text plus extmarks. Keeping the two together means the
--- buffer always contains the full information as *text* — highlights only ever
--- add emphasis, never meaning, which is what makes the UI readable with
--- highlighting off or through a screen reader.

local util = require("ssh_launcher.util")

local M = {}

---@alias ssh_launcher.Chunk { [1]: string, [2]: string|nil }
---@alias ssh_launcher.Line ssh_launcher.Chunk[]

--- Flatten chunks into one buffer line.
---
--- Chunk text is forced onto a single line here, at the boundary, rather than
--- trusting every caller and every data source to have done it: a chunked line
--- maps 1:1 onto a buffer line that views index by number, so a newline can
--- never be allowed to turn one row into two.
---@param chunks ssh_launcher.Line
---@return string text, { hl: string, from: integer, to: integer }[] spans byte ranges
function M.flatten(chunks)
  local parts, spans = {}, {}
  local offset = 0
  for _, chunk in ipairs(chunks) do
    local text = util.single_line(chunk[1])
    local hl = chunk[2]
    parts[#parts + 1] = text
    if hl and #text > 0 then
      spans[#spans + 1] = { hl = hl, from = offset, to = offset + #text }
    end
    offset = offset + #text
  end
  return table.concat(parts), spans
end

--- Write chunked lines into a buffer and apply their highlights.
---@param buf integer
---@param ns integer
---@param lines ssh_launcher.Line[]
---@param opts { start: integer|nil, clear: boolean|nil }|nil
function M.draw(buf, ns, lines, opts)
  opts = opts or {}
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local start = opts.start or 0

  local texts, all_spans = {}, {}
  for i, chunks in ipairs(lines) do
    local text, spans = M.flatten(chunks)
    texts[i] = text
    all_spans[i] = spans
  end

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, opts.clear == false and (start + #texts) or -1, false, texts)
  vim.bo[buf].modifiable = modifiable

  vim.api.nvim_buf_clear_namespace(buf, ns, start, -1)
  for i, spans in ipairs(all_spans) do
    for _, span in ipairs(spans) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, start + i - 1, span.from, {
        end_col = span.to,
        hl_group = span.hl,
        strict = false,
      })
    end
  end
end

--- Highlight every occurrence of `needle` in already-drawn lines.
---@param buf integer
---@param ns integer
---@param needle string
---@param hl string
function M.highlight_matches(buf, ns, needle, hl)
  if not needle or needle == "" then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local lowered = needle:lower()
  for i, line in ipairs(lines) do
    local from = 1
    while true do
      local s, e = line:lower():find(lowered, from, true)
      if not s then
        break
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, s - 1, {
        end_col = e,
        hl_group = hl,
        priority = 200,
        strict = false,
      })
      from = e + 1
    end
  end
end

return M
