-- @noindex

local json = require 'dkjson'
local log = require 'logging'

local CURRENT_PROJECT = 0
local XYPAD_EXTSTATE_NAME = 'XY Pad'
local XYPAD_EXTSTATE_KEY = 'mappings'
local DEFAULT_MAX = 1.0
local DEFAULT_MIN = 0.0
local DEFAULT_INVERT = false
local DEFAULT_BYPASS = false
local DEFAULT_USE_CURVE = true
local function default_curve_visibility()
    return { segments = true, points = true }
end
local DEFAULT_CURVE_COLOR = 0xFF3366FF
local DEFAULT_CURVE_THICKNESS = 2
local DEFAULT_CURVE_POINT_RADIUS = 4
local CURVE_COLORS = {
    0xFF3366FF, -- blue
    0xFF33CC99, -- teal
    0xFFFF9933, -- orange
    0xFFCC33FF, -- purple
    0xFFFF3355, -- red-pink
    0xFF33CCFF, -- cyan
    0xFF66CC33, -- green
    0xFFFFCC33, -- yellow-orange
}

local function normalize_curve_visibility(vis)
    if type(vis) == 'table' then
        return {
            segments = vis.segments ~= false,
            points = vis.points ~= false,
        }
    end

    if vis == 'full' then
        return { segments = true, points = true }
    elseif vis == 'segments' then
        return { segments = true, points = false }
    elseif vis == 'points' then
        return { segments = false, points = true }
    elseif vis == 'none' then
        return { segments = false, points = false }
    end

    return { segments = true, points = true }
end

local function default_curve_points()
    return {
        { x = 0, y = 0 },
        { x = 1, y = 1 },
    }
end

local function normalize_curve_points(points)
    if type(points) ~= 'table' then
        return default_curve_points()
    end

    local normalized = {}
    for _, pt in ipairs(points) do
        if type(pt) == 'table' then
            local x = tonumber(pt.x)
            local y = tonumber(pt.y)
            if x ~= nil and y ~= nil then
                if x < 0 then x = 0 elseif x > 1 then x = 1 end
                if y < 0 then y = 0 elseif y > 1 then y = 1 end
                table.insert(normalized, { x = x, y = y })
            end
        end
    end

    if #normalized < 2 then
        return default_curve_points()
    end

    table.sort(normalized, function(a, b) return a.x < b.x end)
    return normalized
end

-- Builds a map of project tracks and their FX chains
-- Returns a table with the following methods:
--   get_track(guid) -> track, track_number
--   get_fx_number(track_guid, fx_guid) -> fx_number
--   is_valid(mapping) -> boolean
local function mapping_validator()

  local track_fx_map = {}

  for i = 0, reaper.CountTracks(CURRENT_PROJECT) - 1 do
      local track = reaper.GetTrack(CURRENT_PROJECT, i)
      local track_guid = reaper.GetTrackGUID(track)
      local fx_map = {}

      for j = 0, reaper.TrackFX_GetCount(track) - 1 do
          local fx_guid = reaper.TrackFX_GetFXGUID(track, j)
          fx_map[fx_guid] = j
      end

      track_fx_map[track_guid] = {
          track = track,
          track_number = i,
          fx = fx_map
      }
  end

  return {
      get_track = function(guid)
          local found = track_fx_map[guid]

          if not found then
              return nil, nil
          end

          return found.track, found.track_number
      end,

      get_fx_number = function(track_guid, fx_guid)
          local track = track_fx_map[track_guid]

          if not track then
              return nil
          end

          return track.fx[fx_guid]
      end,

      is_valid = function(mapping)
          if not mapping then
              return false
          end

          if not (mapping.track_guid and mapping.fx_guid and mapping.param_number) then
              return false
          end

          local fx_map = track_fx_map[mapping.track_guid]
          if not (fx_map and fx_map.fx and fx_map.fx[mapping.fx_guid]) then
              return false
          end

          return true
      end,
  }
end

local _on_add_mapping = function(_) end
local function on_add_mapping(f)
    _on_add_mapping = f
end

local function empty_mappings() return {}, {} end

local xs, ys = empty_mappings()

local function get_mappings()
    return { x = xs, y = ys }
end

local function pick_curve_color(axis)
    local total = #xs + #ys
    local idx = (total % #CURVE_COLORS) + 1
    return CURVE_COLORS[idx]
end

-- Converts mappings to a dehydrated format for persistence
local function dehydrate(mappings)
    local dehydrated = {}

    for _, m in ipairs(mappings) do
        table.insert(dehydrated, {
            track_guid = m.track_guid,
            fx_guid = m.fx_guid,
            param_number = m.param_number,
            max = m.max,
            min = m.min,
            invert = m.invert,
            bypass = m.bypass,
            use_curve = m.use_curve,
            curve_visibility = m.curve_visibility,
            curve_points = m.curve_points,
            curve_color = m.curve_color,
            curve_thickness = m.curve_thickness,
            curve_point_radius = m.curve_point_radius,
        })
    end

    return dehydrated
end

-- Converts mappings to a hydrated format for active use in the script
local function hydrate(mapping, validator)
    validator = validator or mapping_validator()
    local track_guid = mapping.track_guid
    local fx_guid = mapping.fx_guid
    local param_number = mapping.param_number
    local track, track_number = validator.get_track(track_guid)
    local fx_number = validator.get_fx_number(track_guid, fx_guid)

    if not (track and track_number and fx_number) then
      return
    end

    local _, fx_name = reaper.TrackFX_GetFXName(track, fx_number)

    fx_name = fx_name or ('FX #' .. fx_number)

    local _, param_name = reaper.TrackFX_GetParamName(track, fx_number, param_number)

    param_name = param_name or ('Param #' .. param_number)

    local _, track_name = reaper.GetTrackName(track)

    track_name = track_name or ('Track #' .. track_number)

    local mapping_name = ("%s - %s on '%s'"):format(fx_name, param_name, track_name)

    local use_curve
    if mapping.use_curve == nil then
        use_curve = DEFAULT_USE_CURVE
    else
        use_curve = mapping.use_curve
    end

    return {
        track = track,
        track_guid = track_guid,
        track_number = track_number,
        track_name = track_name,
        fx_guid = fx_guid,
        fx_number = fx_number,
        fx_name = fx_name,
        param_number = param_number,
        param_name = param_name,
        mapping_name = mapping_name,
        max = mapping.max or DEFAULT_MAX,
        min = mapping.min or DEFAULT_MIN,
        invert = mapping.invert or DEFAULT_INVERT,
        bypass = mapping.bypass or DEFAULT_BYPASS,
        use_curve = use_curve,
        curve_visibility = normalize_curve_visibility(mapping.curve_visibility or default_curve_visibility()),
        curve_points = normalize_curve_points(mapping.curve_points),
        curve_color = mapping.curve_color or DEFAULT_CURVE_COLOR,
        curve_thickness = mapping.curve_thickness or DEFAULT_CURVE_THICKNESS,
        curve_point_radius = mapping.curve_point_radius or DEFAULT_CURVE_POINT_RADIUS,
        current_value = 0.0 -- output of the evaluated mapping curve updated each frame
    }
end

local function validated(mappings)
  local validator = mapping_validator()

  local validated_mappings = {}

  for _, m in ipairs(mappings) do
      if validator.is_valid(m) then
          table.insert(validated_mappings, hydrate(m, validator))
      end
  end

  return validated_mappings
end

local function reload_mappings()
  xs, ys = empty_mappings()

  local fetched_extstate, state = reaper.GetProjExtState(CURRENT_PROJECT, XYPAD_EXTSTATE_NAME, XYPAD_EXTSTATE_KEY)

  if fetched_extstate == 1 then
      local mappings = json.decode(state)

      if mappings and type(mappings) == 'table' then
          if mappings.xs then xs = validated(mappings.xs) end
          if mappings.ys then ys = validated(mappings.ys) end
      end
  end
end

-- Checks if a mapping already exists in the mappings table
-- with a matching track guid, fx guid, and param number
local function exists(mapping)
    local function check(m)
        return  m.track_guid   == mapping.track_guid
            and m.fx_guid      == mapping.fx_guid
            and m.param_number == mapping.param_number
    end

    for _, m in ipairs(xs) do
        if check(m) then return true end
    end

    for _, m in ipairs(ys) do
        if check(m) then return true end
    end

    return false
  end

local function save_mappings()
    local mappings = {
        xs = dehydrate(xs),
        ys = dehydrate(ys)
    }

    local m_json = json.encode(mappings)

    if not m_json or type(m_json) ~= 'string' then
        return
    else
        reaper.SetProjExtState(CURRENT_PROJECT, XYPAD_EXTSTATE_NAME, XYPAD_EXTSTATE_KEY, m_json)
        reaper.MarkProjectDirty(CURRENT_PROJECT)
    end
end

local function add_mapping(axis, track_guid, fx_guid, param_number)
    local mappings = axis == 'x' and xs or ys

    local m = {
        axis = axis,
        track_guid = track_guid,
        fx_guid = fx_guid,
        param_number = param_number,
        use_curve = DEFAULT_USE_CURVE,
        curve_visibility = default_curve_visibility(),
        curve_points = default_curve_points(),
        curve_color = pick_curve_color(axis),
        curve_thickness = DEFAULT_CURVE_THICKNESS,
        curve_point_radius = DEFAULT_CURVE_POINT_RADIUS,
    }

    if exists(m) then
        log('Mapping already exists')
        return
    end

    if not mapping_validator().is_valid(m) then
        log('Invalid mapping')
        return
    end

    table.insert(mappings, hydrate(m))

    save_mappings()

    _on_add_mapping(m)
end

local function remove_selected_in(ms)
    local filtered = {}

    for _, m in ipairs(ms) do
        if not m.selected then
            table.insert(filtered, m)
        end
    end

    return filtered
end

local function remove_selected()
    xs = remove_selected_in(xs)
    ys = remove_selected_in(ys)
    save_mappings()
end

local function fx_number_matches_guid(track, fx_number, fx_guid)
    if not track or fx_number == nil or not fx_guid then
        return false
    end

    if fx_number < 0 then
        return false
    end

    local fx_count = reaper.TrackFX_GetCount(track)
    if fx_number >= fx_count then
        return false
    end

    return reaper.TrackFX_GetFXGUID(track, fx_number) == fx_guid
end

local function find_fx_number_by_guid(track, fx_guid)
    if not track or not fx_guid then
        return nil
    end

    local fx_count = reaper.TrackFX_GetCount(track)
    for i = 0, fx_count - 1 do
        if reaper.TrackFX_GetFXGUID(track, i) == fx_guid then
            return i
        end
    end

    return nil
end

local function ensure_fx_number(mapping)
    if not mapping or not mapping.track or not mapping.fx_guid then
        return false
    end

    if fx_number_matches_guid(mapping.track, mapping.fx_number, mapping.fx_guid) then
        return true
    end

    local resolved = find_fx_number_by_guid(mapping.track, mapping.fx_guid)
    if resolved ~= nil then
        mapping.fx_number = resolved
        return true
    end

    if not mapping._warned_missing_fx then
        mapping._warned_missing_fx = true
        log(('FX no longer found for mapping: %s'):format(mapping.mapping_name or '<unknown>'))
    end

    return false
end

-- Takes a single mapping object instead of all mappings on axis
local function set_param_value(mapping, value)
    local adjusted_value = mapping.min + value * (mapping.max - mapping.min)

    if mapping.invert then
        adjusted_value = 1.0 - adjusted_value
    end

    if not mapping.bypass and ensure_fx_number(mapping) and mapping.param_number ~= nil then
        reaper.TrackFX_SetParam(mapping.track, mapping.fx_number, mapping.param_number, adjusted_value)
    end
end

local function is_empty()
    return #xs == 0 and #ys == 0
end

local function mapping_from_last_touched(axis)
    local result, track_num, _item_num, _take_num, fx_num, param_num
        = reaper.GetTouchedOrFocusedFX(0)

    if not result then return end

    local track = reaper.GetTrack(CURRENT_PROJECT, track_num)
    local track_guid = reaper.GetTrackGUID(track)
    local fx_guid = reaper.TrackFX_GetFXGUID(track, fx_num)

    local m = {
        axis = axis,
        track_guid = track_guid,
        fx_guid = fx_guid,
        param_number = param_num,
    }

    local validator = mapping_validator()

    return {
        add = function()
            add_mapping(axis, track_guid, fx_guid, param_num)
        end,

        exists = function()
            return exists(m)
        end,

        is_valid = function()
            return validator.is_valid(m)
        end,
    }
end

return {
    reload_mappings = reload_mappings,
    get_mappings = get_mappings,
    save_mappings = save_mappings,
    add_mapping = add_mapping,
    on_add_mapping = on_add_mapping,
    mapping_from_last_touched = mapping_from_last_touched,
    remove_selected = remove_selected,
    is_empty = is_empty,
    set_param_value = set_param_value,
    with_mappings = function(f)
        local all_mappings = get_mappings()
        for _, m in ipairs(all_mappings.x) do f(m, 'x') end
        for _, m in ipairs(all_mappings.y) do f(m, 'y') end
    end,
    find_mapping = function(f)
        local all_mappings = get_mappings()
        for _, m in ipairs(all_mappings.x) do
            if f(m, 'x') then return m end
        end
        for _, m in ipairs(all_mappings.y) do
            if f(m, 'y') then return m end
        end
        return nil
    end
}