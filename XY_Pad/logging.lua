-- @noindex

local LOG_ENABLED = false
local LOG_TAG = 'XY Pad'
local LOG_TIME_FORMAT = '%Y-%m-%d %H:%M:%S'

local ShowConsoleMsg = reaper.ShowConsoleMsg

local log = function(msg)
  if not LOG_ENABLED then
    return
  end

  local log_string = ("%s [%s] %s\n"):format(
    os.date(LOG_TIME_FORMAT),
    LOG_TAG,
    msg
  )

  ShowConsoleMsg(log_string)
end

return log