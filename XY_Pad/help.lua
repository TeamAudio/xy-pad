-- @noindex

local ImGui = require 'imgui' '0.9.2'

local Trap = require 'trap'

local render, render_content

local colors = {
    white = 0xffffffff,
    off_white = 0xffeeeeee,
    red = 0xff0000ff,
}

render = function(frame)
    local ctx = frame.ctx
    local fonts = frame.fonts

    local child_flags = ImGui.ChildFlags_FrameStyle

    fonts.wrap(ctx, fonts.main, function()
        if ImGui.BeginChild(ctx, 'Help', 0, 0, child_flags) then
            Trap(function()
                render_content(frame)
            end)
            ImGui.EndChild(ctx)
        end
    end)
end

function render_content(frame)
    local ctx = frame.ctx
    local fonts = frame.fonts

    if ImGui.BeginChild(ctx, 'Help-Content', 0, 0, ImGui.ChildFlags_AutoResizeY) then
        Trap(function()
            ImGui.Spacing(ctx)
            ImGui.Spacing(ctx)
            local w, _ = ImGui.GetContentRegionAvail(ctx)
            local c_x = w / 2

            local wrap_width = w * 0.9

            fonts.wrap(ctx, fonts.bigboi, function()
                local title = "Welcome to XY Pad! So glad you're here!"
                local title_w, _ = ImGui.CalcTextSize(ctx, title)
                local title_x = c_x - title_w / 2
                ImGui.SetCursorPosX(ctx, title_x)
                ImGui.Text(ctx, title)
            end, Trap)

            ImGui.Spacing(ctx)
            ImGui.Spacing(ctx)

            ImGui.PushStyleColor(ctx, ImGui.Col_Text, colors.off_white)
            ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 0, 5)

            Trap(function()
                fonts.wrap(ctx, fonts.big, function()
                    ImGui.Text(ctx, "This is a quick guide to get you started.")
                    ImGui.Spacing(ctx)
                    ImGui.TextWrapped(ctx,
                        "It will hide automatically once you've added your first mapping, but will always be available from the menu above by clicking 'Show Help'.")
                end, Trap)

                ImGui.Spacing(ctx)

                fonts.wrap(ctx, fonts.bold, function()
                    ImGui.PushStyleColor(ctx, ImGui.Col_Text, colors.red)
                    Trap(function()
                        ImGui.TextWrapped(ctx,
                            "Important: Mappings and options are stored in your REAPER project. If you do not save your project before closing it, any mappings you've added will be lost.")
                    end)
                    ImGui.PopStyleColor(ctx)
                end)

                ImGui.Spacing(ctx)

                fonts.wrap(ctx, fonts.bold, function()
                    ImGui.Text(ctx, "1. Add a mapping:")
                end, Trap)

                ImGui.Spacing(ctx)

                ImGui.PushTextWrapPos(ctx, 0.0)
                Trap(function()
                    ImGui.Dummy(ctx, 10, 0)
                    ImGui.SameLine(ctx)
                    ImGui.Text(ctx,
                        "Touch the FX param you'd like to control. Then run either 'TA_XY Pad Set X.lua' or 'TA_XY Pad Set Y.lua' to map the parameter to the X or Y axis respectively. You can also select 'Map to X Axis' or 'Map to Y Axis' under the 'Mappings -> New Mapping' menu. You can also hit 'x' or 'y' on your keyboard from the main pad window.")
                end)
                ImGui.PopTextWrapPos(ctx)

                ImGui.Spacing(ctx)

                fonts.wrap(ctx, fonts.bold, function()
                    ImGui.Text(ctx, "2. Click and drag on the pad to control the parameter.")
                end, Trap)

                ImGui.Spacing(ctx)

                ImGui.PushTextWrapPos(ctx, wrap_width)
                Trap(function()
                    ImGui.Dummy(ctx, 10, 0)
                    ImGui.SameLine(ctx)
                    ImGui.Text(ctx, "(0, 0) is the bottom left corner, (1, 1) is the top right corner.")
                end)
                ImGui.PopTextWrapPos(ctx)

                ImGui.Spacing(ctx)

                fonts.wrap(ctx, fonts.bold, function()
                    ImGui.Text(ctx, "3. Explore additional options in the options menu.")
                end, Trap)

                ImGui.Spacing(ctx)

                ImGui.PushTextWrapPos(ctx, wrap_width)
                Trap(function()
                    ImGui.Dummy(ctx, 10, 0)
                    ImGui.SameLine(ctx)
                    ImGui.Text(ctx,
                        "You can control the look and feel of XY pad to match your aesthetic preferences.")
                end)
                ImGui.PopTextWrapPos(ctx)

                ImGui.Spacing(ctx)
            end)

            ImGui.PopStyleVar(ctx)
            ImGui.PopStyleColor(ctx)
        end)
    end
    ImGui.EndChild(ctx)
end

return {
    render = render,
}
