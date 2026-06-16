local M = {}

local items = {}
local next_id = 1

local function find_item(id)
  for index, item in ipairs(items) do
    if item.id == id then
      return item, index
    end
  end
end

function M.run(args)
  args = args or {}
  local action = args.action or "list"

  if action == "add" then
    local text = vim.trim(args.text or "")
    if text == "" then
      return nil, "todo.add requires text"
    end

    local item = {
      id = next_id,
      text = text,
      done = false,
    }
    next_id = next_id + 1
    table.insert(items, item)
    return string.format("Added todo #%d: %s", item.id, item.text)
  end

  if action == "update" then
    local id = tonumber(args.id)
    if not id then
      return nil, "todo.update requires numeric id"
    end

    local item = find_item(id)
    if not item then
      return nil, "Todo item not found: " .. id
    end

    if args.text and vim.trim(args.text) ~= "" then
      item.text = args.text
    end
    if args.done ~= nil then
      item.done = not not args.done
    end

    return string.format("Updated todo #%d: [%s] %s", item.id, item.done and "x" or " ", item.text)
  end

  if action == "remove" then
    local id = tonumber(args.id)
    if not id then
      return nil, "todo.remove requires numeric id"
    end

    local item, index = find_item(id)
    if not item then
      return nil, "Todo item not found: " .. id
    end

    table.remove(items, index)
    return string.format("Removed todo #%d", id)
  end

  if action == "clear" then
    items = {}
    next_id = 1
    return "Cleared all todo items"
  end

  if #items == 0 then
    return "No todo items"
  end

  local lines = { "Todo items:" }
  for _, item in ipairs(items) do
    table.insert(lines, string.format("%d. [%s] %s", item.id, item.done and "x" or " ", item.text))
  end
  return table.concat(lines, "\n")
end

return M

