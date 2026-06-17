if vim.g.loaded_nvim_copilot_extension == 1 then
  return
end

vim.g.loaded_nvim_copilot_extension = 1

if vim.g.loaded_copilot_panel ~= 1 then
  vim.g.loaded_copilot_panel = 1
end
