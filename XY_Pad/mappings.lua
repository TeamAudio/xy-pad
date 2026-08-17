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

local PROJECT_REFRESH_MIN_INTERVAL = 0.25 -- seconds

local function empty_mappings() return {}, {}, { tracks = {} } end

local xs, ys, ms_table = empty_mappings()
local last_project_state_change = reaper.GetProjectStateChangeCount(CURRENT_PROJECT)
local last_project_refresh_time = reaper.time_precise()

-- Re-sync the project-change watermark, so our own saves (which bump the
-- project state count) don't count as an external change and trigger a reload.
local function update_project_update_state()
    last_project_state_change = reaper.GetProjectStateChangeCount(CURRENT_PROJECT)
    last_project_refresh_time = reaper.time_precise()
end

local function get_mappings()
    return { x = xs, y = ys, ms_table = ms_table }
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

    -- Legacy min/max bounds predate curves and used to scale the output in
    -- set_param_value. Fold them into the curve points instead, so old projects
    -- keep their range and the bounds become visible and editable as the curve
    -- itself. Migrated mappings no longer carry min/max; the next save drops
    -- the fields.
    local curve_points = normalize_curve_points(mapping.curve_points)
    local legacy_min = tonumber(mapping.min) or DEFAULT_MIN
    local legacy_max = tonumber(mapping.max) or DEFAULT_MAX
    if legacy_min ~= DEFAULT_MIN or legacy_max ~= DEFAULT_MAX then
        for _, pt in ipairs(curve_points) do
            local y = legacy_min + pt.y * (legacy_max - legacy_min)
            if y < 0 then y = 0 elseif y > 1 then y = 1 end
            pt.y = y
        end
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
        invert = mapping.invert or DEFAULT_INVERT,
        bypass = mapping.bypass or DEFAULT_BYPASS,
        use_curve = use_curve,
        curve_visibility = normalize_curve_visibility(mapping.curve_visibility or default_curve_visibility()),
        curve_points = curve_points,
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

    -- (named _entry to avoid colliding with the module-level ensure_track,
    -- which revalidates a mapping's cached MediaTrack pointer)
    local function ensure_track_entry(m)
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
        local track_entry = ensure_track_entry(m)
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

    -- The lookup maps only exist to build the sorted arrays; strip them so the
    -- returned table has a single representation of the hierarchy.
    for _, track_entry in ipairs(ms_table.tracks) do
        for _, fx_entry in ipairs(track_entry.fx) do
            fx_entry.params_map = nil
        end
        track_entry.fx_map = nil
    end
    ms_table.by_track = nil

    return ms_table
end

-- Persisted-blob schema version. Blobs written before versioning carry no
-- schema_version field and are treated as version 0. migrations[v] upgrades a
-- decoded blob in place from version v to v+1; steps run in order at load.
-- Version 1 is the first stamped format; 0 -> 1 has no structural change
-- (legacy min/max bounds are folded into curve points in hydrate, which must
-- handle unstamped data regardless).
local MAPPINGS_SCHEMA_VERSION = 1
local migrations = {}

local function migrate(blob)
    local version = tonumber(blob.schema_version) or 0

    while version < MAPPINGS_SCHEMA_VERSION do
        local step = migrations[version]
        if step then step(blob) end
        version = version + 1
    end

    blob.schema_version = version
    return blob
end

-- Identity of the mapping currently in curve-edit mode, so edit mode can
-- survive a reload (hydrate builds fresh objects without transient state).
local function find_editing_identity()
    local function scan(ms, axis)
        for _, m in ipairs(ms) do
            if m.is_editing then
                return {
                    track_guid = m.track_guid,
                    fx_guid = m.fx_guid,
                    param_number = m.param_number,
                    axis = axis,
                }
            end
        end
    end
    return scan(xs, 'x') or scan(ys, 'y')
end

local function restore_editing_identity(editing)
    if not editing then return end

    local list = editing.axis == 'x' and xs or ys
    for _, m in ipairs(list) do
        if m.track_guid == editing.track_guid
            and m.fx_guid == editing.fx_guid
            and m.param_number == editing.param_number then
            m.is_editing = true
            -- hydrate doesn't carry axis; without it, curve editing falls back
            -- to X-axis coordinates and mis-transposes edits on a Y mapping.
            m.axis = editing.axis
            return
        end
    end
end

local function reload_mappings()
  update_project_update_state()

  local editing = find_editing_identity()

  xs, ys, ms_table = empty_mappings()

  local fetched_extstate, state = reaper.GetProjExtState(CURRENT_PROJECT, XYPAD_EXTSTATE_NAME, XYPAD_EXTSTATE_KEY)

  if fetched_extstate == 1 then
      local mappings = json.decode(state)

      if mappings and type(mappings) == 'table' then
          mappings = migrate(mappings)
          if mappings.xs then xs = validated(mappings.xs) end
          if mappings.ys then ys = validated(mappings.ys) end
      end
  end

  ms_table = rebuild_ms_table(xs, ys)

  restore_editing_identity(editing)
end

-- Reload when something else changed the project (undo, track/FX edits,
-- another script), rate-limited; our own saves and param writes are excluded
-- via the watermark updates in save_mappings and set_param_value.
local function refresh_if_project_changed()
    local current = reaper.GetProjectStateChangeCount(CURRENT_PROJECT)

    if current ~= last_project_state_change then
        local now = reaper.time_precise()

        if now - last_project_refresh_time >= PROJECT_REFRESH_MIN_INTERVAL then
            reload_mappings()
            return true
        end
    end

    return false
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
        schema_version = MAPPINGS_SCHEMA_VERSION,
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
        update_project_update_state()
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

-- Move an existing mapping to the other axis in place. The object keeps its
-- identity (curve settings and edit state survive), nothing is removed unless
-- the insert can happen, and there is exactly one save.
local function reassign_axis(mapping, axis)
    local from = axis == 'y' and xs or ys
    local to   = axis == 'y' and ys or xs

    for _, m in ipairs(to) do
        if m == mapping then return end
        if m.track_guid == mapping.track_guid
            and m.fx_guid == mapping.fx_guid
            and m.param_number == mapping.param_number then
            log('Mapping already exists on the target axis')
            return
        end
    end

    local filtered = {}
    local found = false
    for _, m in ipairs(from) do
        if m == mapping then
            found = true
        else
            table.insert(filtered, m)
        end
    end

    if not found then return end

    if axis == 'y' then
        xs = filtered
    else
        ys = filtered
    end

    mapping.axis = axis
    table.insert(to, mapping)
    save_mappings()
end

local function remove_mapping(mapping)
    local function without(ms)
        local filtered = {}

        for _, m in ipairs(ms) do
            if mapping ~= m then
                table.insert(filtered, m)
            end
        end

        return filtered
    end

    xs = without(xs)
    ys = without(ys)
    save_mappings()
end

local function find_track_by_guid(track_guid)
    for i = 0, reaper.CountTracks(CURRENT_PROJECT) - 1 do
        local track = reaper.GetTrack(CURRENT_PROJECT, i)
        if reaper.GetTrackGUID(track) == track_guid then
            return track
        end
    end

    return nil
end

-- The cached mapping.track pointer goes stale when its track is deleted (or
-- deleted and restored via undo, which allocates a new MediaTrack). Validate it
-- before use and re-resolve it from the persisted track GUID, so mappings
-- self-heal instead of passing a dangling pointer to TrackFX_* calls.
local function ensure_track(mapping)
    if not mapping or not mapping.track_guid then
        return false
    end

    if mapping.track and reaper.ValidatePtr2(CURRENT_PROJECT, mapping.track, 'MediaTrack*') then
        return true
    end

    -- Re-scan only when the project has changed since the last failed attempt,
    -- so a dead mapping doesn't cost a full track scan every frame.
    local state_count = reaper.GetProjectStateChangeCount(CURRENT_PROJECT)
    if mapping._track_resolve_state == state_count then
        return false
    end
    mapping._track_resolve_state = state_count

    local track = find_track_by_guid(mapping.track_guid)
    if track then
        mapping.track = track
        mapping._warned_missing_track = nil
        return true
    end

    if not mapping._warned_missing_track then
        mapping._warned_missing_track = true
        log(('Track no longer found for mapping: %s'):format(mapping.mapping_name or '<unknown>'))
    end

    return false
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
    if not mapping or not mapping.fx_guid then
        return false
    end

    if not ensure_track(mapping) then
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
    local adjusted_value = value

    if mapping.invert then
        adjusted_value = 1.0 - adjusted_value
    end

    if not mapping.bypass and ensure_fx_number(mapping) and mapping.param_number ~= nil then
        reaper.TrackFX_SetParam(mapping.track, mapping.fx_number, mapping.param_number, adjusted_value)
        -- Param writes bump the project state count; re-arm the watermark so
        -- our own pad drags don't trigger the mappings-window auto-refresh.
        update_project_update_state()
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
    refresh_if_project_changed = refresh_if_project_changed,
    get_mappings = get_mappings,
    save_mappings = save_mappings,
    add_mapping = add_mapping,
    on_add_mapping = on_add_mapping,
    mapping_from_last_touched = mapping_from_last_touched,
    remove_mapping = remove_mapping,
    reassign_axis = reassign_axis,
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