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

local function empty_mappings() return {}, {}, {} end

local xs, ys, ms_table = empty_mappings()

local function get_mappings()
    return { x = xs, y = ys, ms_table = ms_table }
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
            bypass = m.bypass
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
        bypass = mapping.bypass or DEFAULT_BYPASS
    }
end

local function validated(mappings)
  local validator = mapping_validator()

  local validated_mappings = {}

  for _, m in ipairs(mappings) do
      if validator.is_valid(m) then
          table.insert(validated_mappings, hydrate(m))
      end
  end

  return validated_mappings
end

-- Build a deterministic hierarchy Track->FX->Param with both lookups and sorted arrays
local function rebuild_ms_table(xs, ys)
    local ms_table = { tracks = {}, by_track = {} }

    local function sorted_values(map, cmp)
        local arr = {}

        for _, v in pairs(map) do
            table.insert(arr, v)
        end

        table.sort(arr, cmp)

        return arr
    end

    local function ensure_track(m)
        local track_entry = ms_table.by_track[m.track_guid]

        if not track_entry then
            track_entry = {
                guid = m.track_guid,
                name = m.track_name,
                track_number = m.track_number,
                fx_map = {}
            }
            ms_table.by_track[m.track_guid] = track_entry
            table.insert(ms_table.tracks, track_entry)
        end

        return track_entry
    end

    local function ensure_fx(track_entry, m)
        local fx_entry = track_entry.fx_map[m.fx_guid]

        if not fx_entry then
            fx_entry = {
                guid = m.fx_guid,
                name = m.fx_name,
                fx_number = m.fx_number,
                params_map = {}
            }
            track_entry.fx_map[m.fx_guid] = fx_entry
        end

        return fx_entry
    end

    local function ensure_param(fx_entry, m)
        local param_entry = fx_entry.params_map[m.param_number]

        if not param_entry then
            param_entry = {
                param_number = m.param_number,
                name = m.param_name,
                mappings = {}
            }
            fx_entry.params_map[m.param_number] = param_entry
        end

        return param_entry
    end

    local function insert_mapping(m, axis)
        local track_entry = ensure_track(m)
        local fx_entry = ensure_fx(track_entry, m)
        local param_entry = ensure_param(fx_entry, m)

        param_entry.mappings[axis] = m
    end

    for _, m in ipairs(xs) do
        insert_mapping(m, 'x')
    end

    for _, m in ipairs(ys) do
        insert_mapping(m, 'y')
    end

    for _, track_entry in ipairs(ms_table.tracks) do
        track_entry.fx = sorted_values(track_entry.fx_map, function(a, b)
            local a_name = (a.name or ""):lower()
            local b_name = (b.name or ""):lower()

            if a_name ~= b_name then return a_name < b_name end

            if a.fx_number and b.fx_number and a.fx_number ~= b.fx_number then
                return a.fx_number < b.fx_number
            end

            return (a.guid or "") < (b.guid or "")
        end)

        for _, fx_entry in ipairs(track_entry.fx) do
            fx_entry.params = sorted_values(fx_entry.params_map, function(a, b)
                if a.param_number ~= b.param_number then
                    return a.param_number < b.param_number
                end

                local a_name = (a.name or ""):lower()
                local b_name = (b.name or ""):lower()

                return a_name < b_name
            end)
        end
    end

    table.sort(ms_table.tracks, function(a, b)
        if a.track_number and b.track_number and a.track_number ~= b.track_number then
            return a.track_number < b.track_number
        end

        local a_name = (a.name or ""):lower()
        local b_name = (b.name or ""):lower()

        if a_name ~= b_name then return a_name < b_name end

        return (a.guid or "") < (b.guid or "")
    end)

    return ms_table
end

local function reload_mappings()
  xs, ys, ms_table = empty_mappings()

  local fetched_extstate, state = reaper.GetProjExtState(CURRENT_PROJECT, XYPAD_EXTSTATE_NAME, XYPAD_EXTSTATE_KEY)

  if fetched_extstate == 1 then
      local mappings = json.decode(state)

      if mappings and type(mappings) == 'table' then
          if mappings.xs then xs = validated(mappings.xs) end
          if mappings.ys then ys = validated(mappings.ys) end
      end

      ms_table = rebuild_ms_table(xs, ys)
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
        ms_table = rebuild_ms_table(xs, ys)
    end
end

local function add_mapping(axis, track_guid, fx_guid, param_number, config)
    local mappings = axis == 'x' and xs or ys
    config = config or {}

    local m = {
        axis = axis,
        track_guid = track_guid,
        fx_guid = fx_guid,
        param_number = param_number
    }

    if exists(m) then
        log('Mapping already exists')
        return
    end

    for k, v in pairs(config) do
        if k ~= 'axis' then
            m[k] = v
        end
    end

    if not mapping_validator().is_valid(m) then
        log('Invalid mapping')
        return
    end

    table.insert(mappings, hydrate(m))

    save_mappings()

    _on_add_mapping(m)
end

local function remove_mapping(mapping)
    local filtered = {}

    for _, m in ipairs(xs) do
        if mapping ~= m then
            table.insert(filtered, m)
        end
    end

    xs = filtered

    filtered = {}

    for _, m in ipairs(ys) do
        if mapping ~= m then
            table.insert(filtered, m)
        end
    end

    ys = filtered

    save_mappings()
end

local function set_params(axis, value)
    local mappings = axis == 'x' and xs or ys

    for _, m in ipairs(mappings) do
        if not m.bypass then
            local adjusted_value = m.min + value * (m.max - m.min)

            if m.invert then
                adjusted_value = 1.0 - adjusted_value
            end

            reaper.TrackFX_SetParam(m.track, m.fx_number, m.param_number, adjusted_value)
        end
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
    remove_mapping = remove_mapping,
    set_params = set_params,
    is_empty = is_empty
}