-- @noindex

local json = require 'dkjson'
local log = require 'logging'

local EXTSTATE_EXTENSION = 'XY Pad'
local EXTSTATE_KEY = 'add_mapping'

local function get_last_touched_fx()
  local mode = 0 -- 0 = last touched FX, 1 = focused FX
  local retval, track_num, _item_num, _take_num, fx_num, param_num
      = reaper.GetTouchedOrFocusedFX(mode)
  return retval, track_num, fx_num, param_num
end

local function send_param(axis)
    local retval, track_num, fx_num, param_num = get_last_touched_fx()

    if not retval then return end

    local track = reaper.GetTrack(0, track_num)

    local track_guid = reaper.GetTrackGUID(track)

    local fx_guid = reaper.TrackFX_GetFXGUID(track, fx_num)

    local json_str = json.encode({
        axis = axis,
        track_guid = track_guid,
        fx_guid = fx_guid,
        param_number = param_num,
    })

    if not json_str then
        log("Error encoding JSON")
        return
    end

    reaper.SetExtState(EXTSTATE_EXTENSION, EXTSTATE_KEY, json_str, false)
end

local function receive_param()
    local incoming_json = reaper.GetExtState(EXTSTATE_EXTENSION, EXTSTATE_KEY)

    -- Nothing to do here
    if not incoming_json or incoming_json == '' then
        return
    end

    local m = json.decode(incoming_json)

    if not m or type(m) ~= 'table' then
        log("Error decoding JSON")
        return
    end

    local msg = 'Received mapping: axis: %s, track_guid: %s, fx_guid: %s, param_number: %s'
    log(msg:format(m.axis, m.track_guid, m.fx_guid, m.param_number))

    reaper.DeleteExtState(EXTSTATE_EXTENSION, EXTSTATE_KEY, true)

    return {
      axis = m.axis,
      track_guid = m.track_guid,
      fx_guid = m.fx_guid,
      param_number = m.param_number
    }
end

return {
    send_param = send_param,
    receive_param = receive_param,
    get_last_touched_fx = get_last_touched_fx,
}