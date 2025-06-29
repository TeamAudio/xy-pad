-- @noindex

local ImGui = require 'imgui' '0.9.2'
local Trap = require 'trap'
local Widgets = require 'widgets'

local training_axis = nil

local REAPER_CURRENT_PROJECT = 0

local function reset_training()
    training_axis = nil
end

local function update_training_state(axis, mappings)
    training_axis = axis

    local mapping = mappings.mapping_from_last_touched(axis)

    if mapping and mapping.is_valid() and not mapping.exists() then
        mapping.add()
        reset_training()
    end
end

local function train(axis, mappings)
    update_training_state(axis, mappings)
end

local function _project_has_tracks()
    return reaper.CountTracks(REAPER_CURRENT_PROJECT) > 0
end

local function _project_has_fx()
    for i = 0, reaper.CountTracks(REAPER_CURRENT_PROJECT) - 1 do
        local track = reaper.GetTrack(REAPER_CURRENT_PROJECT, i)
        if reaper.TrackFX_GetCount(track) > 0 then
            return true
        end
    end
    return false
end

local function is_training()
    return training_axis ~= nil
end

local function render(frame, mappings)
    local ctx = frame.ctx
    local fonts = frame.fonts

    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
        reset_training()
        return
    end

    update_training_state(training_axis, mappings)

    if not is_training() then
        return
    end

    Widgets:set_ctx(ctx)

    local w, h = ImGui.GetContentRegionAvail(ctx)
    local c_x, c_y = w / 2, h / 3

    fonts.wrap(ctx, fonts.bigboi, function()
        local text = "Training " .. tostring(training_axis):upper() .. " Axis"
        local text_w, _ = ImGui.CalcTextSize(ctx, text)
        local text_x = c_x - text_w / 2
        ImGui.SetCursorPos(ctx, text_x, c_y)
        ImGui.Text(ctx, text)
        ImGui.Spacing(ctx)
        ImGui.Spacing(ctx)
        ImGui.Spacing(ctx)

        if not _project_has_tracks() then
            text = "No tracks in project"
        elseif not _project_has_fx() then
            text = "No FX in project"
        else
            text = "Touch an unmapped parameter to map it to the pad."
        end

        fonts.wrap(ctx, fonts.big, function()
            text_w, _ = ImGui.CalcTextSize(ctx, text)
            text_x = c_x - text_w / 2
            ImGui.SetCursorPosX(ctx, text_x)
            ImGui.Text(ctx, text)
            ImGui.Spacing(ctx)
            text = "[Cancel]"
            text_w, _ = ImGui.CalcTextSize(ctx, text)
            text_x = c_x - text_w / 2
            ImGui.SetCursorPosX(ctx, text_x)
            Widgets.link(text, function()
                reset_training()
            end, 0xff0000ff, 0xff0000ff)
        end, Trap)
    end, Trap)
end

return {
    is_training = is_training,
    render = render,
    train = train,
}
