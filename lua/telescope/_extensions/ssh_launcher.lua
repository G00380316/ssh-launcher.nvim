-- Telescope extension: `:Telescope ssh_launcher`
--
--   require("telescope").load_extension("ssh_launcher")
--
-- The picker itself lives in ssh_launcher.ui.picker; this file exists only so
-- Telescope can find it by name.

local ok, telescope = pcall(require, "telescope")
if not ok then
  error("telescope.nvim is not installed")
end

return telescope.register_extension({
  exports = {
    ssh_launcher = function(opts)
      require("ssh_launcher").ensure_setup()
      require("ssh_launcher.ui.picker").telescope(opts)
    end,
  },
})
