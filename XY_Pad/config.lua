-- @noindex

local json = require 'dkjson'
local log = require 'logging'

local CURRENT_PROJECT = 0
local EXTSTATE_EXTENSION = 'XY Pad'
local EXTSTATE_KEY = 'config'

local DEFAULT_X_LINES = 1
local DEFAULT_Y_LINES = 1
local DEFAULT_GRID_LINES_LINKED = true
local DEFAULT_GRID_LINE_X_COLOR = 0xFFFFFFFF
local DEFAULT_GRID_LINE_Y_COLOR = 0xFFFFFFFF
local DEFAULT_GRID_LINES_LINKED_COLOR = true
local DEFAULT_GRID_LINE_WIDTH = 1.0

local DEFAULT_PAD_BG_COLOR = 0x000000FF
local DEFAULT_PAD_LABEL_COLOR = 0xFFFFFFFF
local DEFAULT_CURSOR_COLOR = 0xFF0000FF
local DEFAULT_CURSOR_RADIUS = 10
local DEFAULT_CURSOR_STROKE = 2

local function save_config(config)
  local json_str = json.encode(config)

  if type(json_str) ~= "string" then
      log("Error encoding JSON")
      return
  end

  reaper.SetProjExtState(CURRENT_PROJECT, EXTSTATE_EXTENSION, EXTSTATE_KEY, json_str)
end

local function default_config()
  return {
    x_lines = DEFAULT_X_LINES,
    y_lines = DEFAULT_Y_LINES,
    grid_lines_linked = DEFAULT_GRID_LINES_LINKED,
    grid_line_x_color = DEFAULT_GRID_LINE_X_COLOR,
    grid_line_y_color = DEFAULT_GRID_LINE_Y_COLOR,
    grid_lines_linked_color = DEFAULT_GRID_LINES_LINKED_COLOR,
    grid_line_width = DEFAULT_GRID_LINE_WIDTH,
    pad_bg_color = DEFAULT_PAD_BG_COLOR,
    pad_label_color = DEFAULT_PAD_LABEL_COLOR,
    cursor_color = DEFAULT_CURSOR_COLOR,
    cursor_radius = DEFAULT_CURSOR_RADIUS,
    cursor_stroke = DEFAULT_CURSOR_STROKE,
  }
end

local function load_config()

  local config = default_config()

  local _, json_str = reaper.GetProjExtState(CURRENT_PROJECT, EXTSTATE_EXTENSION, EXTSTATE_KEY)

  if not json_str or json_str == '' then
    log("Error fetching JSON")
    return config
  end

  local decoded_json = json.decode(json_str)

  if type(decoded_json) ~= 'table' then
    log("Error decoding JSON")
    return config
  end

  for k, v in pairs(config) do
      local value = decoded_json[k]
      if value ~= nil then
          config[k] = value
      end
  end

  return config
end

return {
  save_config = save_config,
  load_config = load_config
}

