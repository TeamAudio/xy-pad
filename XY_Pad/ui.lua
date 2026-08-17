-- @noindex

package.path = package.path .. ';' .. reaper.ImGui_GetBuiltinPath() .. '/?.lua'

local ImGui = require 'imgui' '0.9.2'
local mappings = require 'mappings'
local config = require 'config'
local Fonts = require 'fonts'
local help = require 'help'
local training = require 'training'
local Trap = require 'trap'

local RIGHT_BTN = ImGui.MouseButton_Right or 1

local IMGUI_CONTEXT_NAME = 'XY Pad'
local STORAGE_SECTION = 'XYPad.General'

local DEFAULT_MAPPINGS_WINDOW_WIDTH = 1300
local DEFAULT_MAPPINGS_WINDOW_HEIGHT = 600

-- Shared value ranges: the mappings-window inputs and the pad renderer clamp
-- against the same numbers.
local CURVE_THICKNESS = { default = 2, min = 1, max = 6 }
local CURVE_POINT_RADIUS = { default = 4, min = 2, max = 20 }

local _ctx = ImGui.CreateContext(IMGUI_CONTEXT_NAME)
Fonts:init(_ctx, STORAGE_SECTION)

local mappings_open = false
local options_open = false
local help_open = false
local default_help_open = false

local mouse_down = false

-- Per-project option (set each frame from config)
local transpose_y_curve = true

-- Coordinate helpers: normalized (0-1) <-> screen space
local function get_window_dimensions()
    local win_x, win_y = ImGui.GetWindowPos(_ctx)
    local win_w, win_h = ImGui.GetWindowSize(_ctx)

    return { x = win_x, y = win_y, w = win_w, h = win_h }
end

local function make_point(x, y)
    return { x = x, y = y }
end

local function norm_to_screen(win, point)
    local nx_val, ny_val = point.x, point.y
    local px = win.x + nx_val * win.w
    local py = win.y + (1 - ny_val) * win.h
    return px, py
end

local function screen_to_norm(win, screen_point)
    local nx = (screen_point.x - win.x) / win.w
    local ny = 1 - ((screen_point.y - win.y) / win.h)
    return nx, ny
end

-- curve_visibility is guaranteed normalized ({segments=, points=}) by hydrate;
-- read it directly instead of re-normalizing per frame.
local function visibility_label(flags)
    if flags.segments and flags.points then return 'both' end
    if flags.segments then return 'segments' end
    if flags.points then return 'points' end
    return 'hidden'
end

local function clamp_int(value, default, min_val, max_val)
    local n = tonumber(value)
    if n == nil then
        n = default
    end
    n = math.floor(n + 0.5)
    if n < min_val then
        return min_val
    end
    if n > max_val then
        return max_val
    end
    return n
end

-- Mapping curves
local dragging_point_index = nil
local dragging_point_dirty = false

local function sort_curve(curve_points)
    if not curve_points or #curve_points < 2 then return end
    table.sort(curve_points, function(a, b) return a.x < b.x end)
end

local function sorted_curve_points(points)
    if not points then return {} end
    local ordered = {}
    for _, p in ipairs(points) do
        table.insert(ordered, p)
    end
    sort_curve(ordered)
    return ordered
end

-- Curve coordinate mapping
-- Stored curve points are always { x = input, y = output } in [0,1].
-- For Y-axis mappings, input is vertical and output is horizontal on screen, so we transpose for display/edit.
local function curve_to_display_point(axis, pt)
    if axis == 'y' and transpose_y_curve then
        return { x = pt.y, y = pt.x }
    end
    return { x = pt.x, y = pt.y }
end

local function display_to_curve_point(axis, display_pt)
    if axis == 'y' and transpose_y_curve then
        return { x = display_pt.y, y = display_pt.x }
    end
    return { x = display_pt.x, y = display_pt.y }
end

local function curve_point_to_screen(win, axis, pt)
    return norm_to_screen(win, curve_to_display_point(axis, pt))
end

-- Curve helpers
local function toggle_editing_mapping(axis, m)
    local was_editing = m and m.is_editing

    -- Sweep editing flags so only one mapping is marked editing
    mappings.with_mappings(function(m_)
        m_.is_editing = false
    end)

    if m then
        -- toggle off if clicking the same mapping that was already editing
        m.is_editing = not was_editing
        m.axis = axis
    end
end

local function handle_point_hover_and_delete(editing_curve, win, axis, hover_radius)
    local needs_curve_save = false

    hover_radius = hover_radius or 6

    for i, pt in ipairs(editing_curve or {}) do
        local is_endpoint = (i == 1 or i == #editing_curve)
        local px, py = curve_point_to_screen(win, axis, pt)

        local radius = hover_radius

        if ImGui.IsMouseHoveringRect(_ctx, px - radius, py - radius, px + radius, py + radius) then
            ImGui.SetMouseCursor(_ctx, ImGui.MouseCursor_Hand)

            if ImGui.IsMouseClicked(_ctx, RIGHT_BTN) and ImGui.GetKeyMods(_ctx) ~= ImGui.Mod_Alt then
                dragging_point_index = i
                dragging_point_dirty = false
            end

            if not is_endpoint
            and ImGui.IsMouseClicked(_ctx, RIGHT_BTN)
            and ImGui.GetKeyMods(_ctx) == ImGui.Mod_Alt then
                table.remove(editing_curve, i)
                dragging_point_index = nil
                needs_curve_save = true
                break
            end
        end
    end

    return needs_curve_save
end

local function handle_point_drag(editing_curve, win, axis)
    if not dragging_point_index then return false end

    local pt = editing_curve[dragging_point_index]
    local mx, my = ImGui.GetMousePos(_ctx)
    local new_x, new_y = screen_to_norm(win, make_point(mx, my))

    new_x = math.max(0, math.min(1, new_x))
    new_y = math.max(0, math.min(1, new_y))

    local is_endpoint = (dragging_point_index == 1 or dragging_point_index == #editing_curve)

    local old_x, old_y = pt.x, pt.y

    local curve_pt = display_to_curve_point(axis, { x = new_x, y = new_y })

    if is_endpoint then
        -- Endpoints lock input (pt.x), allow output (pt.y) to change.
        pt.y = curve_pt.y
    else
        pt.x = curve_pt.x
        pt.y = curve_pt.y
    end

    if pt.x ~= old_x or pt.y ~= old_y then
        dragging_point_dirty = true
    end

    return dragging_point_dirty
end

local function render_curve(draw_list, m, win, axis)
    if not m.use_curve or not m.curve_points or #m.curve_points < 2 then return end

    local vis = m.curve_visibility
    local is_editing = m.is_editing

    local point_radius = clamp_int(m.curve_point_radius, CURVE_POINT_RADIUS.default, CURVE_POINT_RADIUS.min, CURVE_POINT_RADIUS.max)
    local point_color = m.curve_color
    local line_thickness = clamp_int(m.curve_thickness, CURVE_THICKNESS.default, CURVE_THICKNESS.min, CURVE_THICKNESS.max)
    local line_color = m.curve_color

    -- During an active drag, render using an x-sorted view so segments always connect left-to-right
    -- without mutating persisted point order every frame. Otherwise, render the stored order
    -- (which is already sorted on add/save).
    local ordered_points
    if is_editing and dragging_point_index then
        ordered_points = sorted_curve_points(m.curve_points)
    else
        ordered_points = m.curve_points
    end

    for i, pt in ipairs(ordered_points) do

        if (is_editing or vis.segments) and i < #ordered_points then
            local p2 = ordered_points[i + 1]
            local x2, y2 = curve_point_to_screen(win, axis, p2)
            local x1, y1 = curve_point_to_screen(win, axis, pt)

            ImGui.DrawList_AddLine(draw_list, x1, y1, x2, y2, line_color, line_thickness)
        end

        if is_editing or vis.points then
            local px, py = curve_point_to_screen(win, axis, pt)

            -- Always draw the filled point using per-mapping radius/color (to be customizable later)
            ImGui.DrawList_AddCircleFilled(draw_list, px, py, point_radius, point_color)

            -- When editing, add a thin white ring outside the point to increase grab area
            if is_editing then
                local ring_radius = point_radius + 3
                ImGui.DrawList_AddCircle(draw_list, px, py, ring_radius, 0xFFFFFFFF, 0, 2)
            end
        end
    end
end

local function render_curves(draw_list, win)
    local top_curve = nil
    local top_curve_axis = nil

    mappings.with_mappings(function(m, axis)
        if m.is_editing then
            top_curve = m
            top_curve_axis = axis
        else
            render_curve(draw_list, m, win, axis)
        end
    end)

    if top_curve then
        render_curve(draw_list, top_curve, win, top_curve_axis)
    end
end

local function process_curve_points(win, mse_norm_x, mse_norm_y, is_mouse_in_bounds, is_pad_hovered)
    local editing_mapping = mappings.find_mapping(function(m) return m.is_editing end)
    if not editing_mapping then
        dragging_point_index = nil
        dragging_point_dirty = false
        return false
    end

    local axis = editing_mapping.axis or 'x'

    local editing_curve = editing_mapping.curve_points or {}

    local point_radius = clamp_int(editing_mapping.curve_point_radius, CURVE_POINT_RADIUS.default, CURVE_POINT_RADIUS.min, CURVE_POINT_RADIUS.max)
    local hover_radius = math.max(6, point_radius + 3)

    -- Only initiate point interactions (hover cursor, drag start, delete, add) while the
    -- pad is the hovered window, so clicks meant for an overlapping window don't edit the
    -- curve underneath. An already-active drag continues below regardless of hover.
    local needs_curve_save = false
    if is_pad_hovered then
        needs_curve_save = handle_point_hover_and_delete(editing_curve, win, axis, hover_radius)
    end

    -- Add new point on right-click if not dragging existing point
    if not dragging_point_index
        and is_mouse_in_bounds
        and is_pad_hovered
        and ImGui.IsMouseClicked(_ctx, RIGHT_BTN)
        and ImGui.GetKeyMods(_ctx) == 0 then
        local curve_pt = display_to_curve_point(axis, { x = mse_norm_x, y = mse_norm_y })
        table.insert(editing_curve, curve_pt)
        sort_curve(editing_curve)
        needs_curve_save = true
    end

    if dragging_point_index and ImGui.IsMouseDown(_ctx, RIGHT_BTN) then -- Drag existing point (in-memory only)
        handle_point_drag(editing_curve, win, axis)
    elseif dragging_point_index and not ImGui.IsMouseDown(_ctx, RIGHT_BTN) then -- Release drag (commit)
        if dragging_point_dirty then
            local was_endpoint = (dragging_point_index == 1 or dragging_point_index == #editing_curve)
            if not was_endpoint then
                sort_curve(editing_curve)
            end
            needs_curve_save = true
        end
        dragging_point_index = nil
        dragging_point_dirty = false
    end

    return needs_curve_save
end

local function marker_position(axis, input_norm, value_norm, win)
    if axis == 'y' and transpose_y_curve then
        return norm_to_screen(win, make_point(value_norm, input_norm))
    end
    return norm_to_screen(win, make_point(input_norm, value_norm))
end

local function draw_mapping_marker(draw_list, m, axis, input_norm, win, options)
    if not (m and m.current_value) or m.bypass then return end
    local marker_x, marker_y = marker_position(axis, input_norm, m.current_value, win)
    local color = m.curve_color or options.cursor_color
    local radius = clamp_int(m.curve_point_radius, 4, 2, 20)
    ImGui.DrawList_AddCircleFilled(draw_list, marker_x, marker_y, radius, color)

    -- Attach a small label to the marker so values are visible while dragging
    local label = string.format('%.2f', m.current_value)
    local label_w, label_h = ImGui.CalcTextSize(_ctx, label)
    local label_x = math.min(win.x + win.w - label_w - 2, marker_x + 6)
    local label_y = math.max(win.y + 2, marker_y - label_h - 2)
    ImGui.DrawList_AddText(draw_list, label_x, label_y, color, label)
end

-- Evaluate mapping curve for a normalized input in [0,1]
local function evaluate_curve(x, curve_points)
    if not curve_points or #curve_points < 2 then
        return x
    end

    for i = 1, #curve_points - 1 do
        local p1, p2 = curve_points[i], curve_points[i+1]
        if x >= p1.x and x <= p2.x then
            if p2.x == p1.x then
                return p1.y
            end
            local t = (x - p1.x) / (p2.x - p1.x)
            return p1.y * (1 - t) + p2.y * t
        end
    end

    if x < curve_points[1].x then return curve_points[1].y end
    if x > curve_points[#curve_points].x then return curve_points[#curve_points].y end

    return x -- fallback value
end

local function evaluate_mapping_and_set(m, input_value)
    if m.bypass then return end

    local val
    if m.use_curve ~= false and m.curve_points and #m.curve_points >= 2 then
        val = evaluate_curve(input_value, m.curve_points)
    end
    if val == nil then
        val = input_value
    end

    mappings.set_param_value(m, val)
    m.current_value = val
end

-- Get mouse position and return raw and normalized values
local function get_mouse_position(win)
    local mse_x, mse_y = ImGui.GetMousePos(_ctx)
    local mse_norm_x, mse_norm_y = (mse_x - win.x)/win.w, 1-(mse_y - win.y)/win.h
    local mse_round_x, mse_round_y = tonumber(string.format('%.2f', mse_norm_x)), tonumber(string.format('%.2f', mse_norm_y))
    return mse_x, mse_y, mse_norm_x, mse_norm_y, mse_round_x, mse_round_y
end

-- Check if mouse is within window bounds
local function mouse_in_bounds(x, y, win)
    return x > win.x and x < win.x + win.w and y > win.y and y < win.y + win.h
end

-- Draw XY lines
local function draw_xy(draw_list, x, y, w, h, x_color, y_color, x_lines, y_lines, line_width)
    for i = 1, x_lines do
        ImGui.DrawList_AddLine(draw_list, x + (w/(x_lines + 1))*i, y, x + (w/(x_lines + 1))*i, y + h, x_color, line_width)
    end

    for i = 1, y_lines do
        ImGui.DrawList_AddLine(draw_list, x, y + (h/(y_lines + 1))*i, x + w, y + (h/(y_lines + 1))*i, y_color, line_width)
    end
end

-- Draw cursor circle
local function draw_cursor(draw_list, x, y, col, radius, stroke)
    ImGui.DrawList_AddCircle(draw_list, x, y, radius, col, 0, stroke)
end

-- Write X and Y values
local function label(draw_list, x, y, msg, col)
    Fonts.wrap(_ctx, Fonts.bigboi, function()
        ImGui.DrawList_AddText(draw_list, x, y, col, msg)
    end, Trap)
end

local function show_or_hide(is_open)
    return is_open and "Hide" or "Show"
end

-- Open Mapping window
local function xy_menu_bar()
    if ImGui.BeginMenuBar(_ctx) then
        Trap(function()
            if ImGui.BeginMenu(_ctx, 'Mappings') then
                Trap(function()
                    if mappings.is_empty() then
                        ImGui.MenuItem(_ctx, 'No mappings', nil, false, false)
                    else
                        if ImGui.MenuItem(_ctx, show_or_hide(mappings_open) .. ' Mappings', nil, mappings_open) then
                            mappings_open = not mappings_open
                        end
                    end

                    if ImGui.BeginMenu(_ctx, "New Mapping") then
                        Trap(function()
                            if ImGui.MenuItem(_ctx, "Map to X Axis", 'x') then
                                training.train('x', mappings)
                            end

                            if ImGui.MenuItem(_ctx, "Map to Y Axis", 'y') then
                                training.train('y', mappings)
                            end
                        end)
                        ImGui.EndMenu(_ctx)
                    end
                end)
                ImGui.EndMenu(_ctx)
            end

            if ImGui.MenuItem(_ctx, show_or_hide(options_open) .. ' Options', nil, options_open) then
                options_open = not options_open
            end

            local either_help_open = help_open or default_help_open
            if ImGui.MenuItem(_ctx, show_or_hide(either_help_open) .. ' Help', nil, either_help_open, not mappings.is_empty()) then
                help_open = not help_open
            end
        end)
        ImGui.EndMenuBar(_ctx)
    end
end

local function render_xy_pad(frame)
    local options = frame.options
    local child_flags = ImGui.ChildFlags_FrameStyle

    Fonts.wrap(_ctx, Fonts.main, function()
        ImGui.PushStyleColor(_ctx, ImGui.Col_FrameBg, options.pad_bg_color)
        Trap(function()
            ImGui.BeginChild(_ctx, 'xy-pad', 0, 0, child_flags, 0)
            Trap(function()
                ImGui.SetConfigVar(_ctx, ImGui.ConfigVar_WindowsMoveFromTitleBarOnly, 1)
                local font_height = ImGui.GetFontSize(_ctx)

                local win = get_window_dimensions()
                local draw_list = ImGui.GetWindowDrawList(_ctx)

                local mse_screen_x, mse_screen_y, mse_norm_x, mse_norm_y, mse_round_x, mse_round_y = get_mouse_position(win)

                local needs_curve_save = false

                draw_xy(draw_list, win.x, win.y, win.w, win.h, options.grid_line_x_color, options.grid_line_y_color, options.x_lines, options.y_lines, options.grid_line_width)

                render_curves(draw_list, win)
                local is_mouse_in_bounds = mouse_in_bounds(mse_screen_x, mse_screen_y, win)
                -- False when another window (Mappings, Options, ...) is on top of the pad
                -- at the mouse position, unlike the purely geometric mouse_in_bounds.
                local is_pad_hovered = ImGui.IsWindowHovered(_ctx)

                if is_mouse_in_bounds and is_pad_hovered then
                    ImGui.SetMouseCursor(_ctx, 7)
                end

                needs_curve_save = process_curve_points(
                    win,
                    mse_norm_x, mse_norm_y,
                    is_mouse_in_bounds,
                    is_pad_hovered
                ) or needs_curve_save

                if is_mouse_in_bounds then
                    if ImGui.IsMouseDown(_ctx, 0) and ImGui.IsWindowFocused(_ctx) then
                        if not mouse_down then
                            mouse_down = true
                        end
                        draw_cursor(draw_list, mse_screen_x, mse_screen_y, options.cursor_color, options.cursor_radius, options.cursor_stroke)
                        label(draw_list, win.x + 5, (win.y - 5) + (win.h - font_height - 5), 'X: ' .. mse_round_x .. ', Y: ' .. mse_round_y, options.pad_label_color)
                        
                        mappings.with_mappings(function(m, axis)
                            local axis_norm = axis == 'x' and mse_norm_x or mse_norm_y
                            evaluate_mapping_and_set(m, axis_norm)
                            draw_mapping_marker(draw_list, m, axis, axis_norm, win, options)
                        end)
                    else
                        mouse_down = false
                    end
                end
                if needs_curve_save then
                    mappings.save_mappings()
                end
            end)

            ImGui.EndChild(_ctx)
        end)
        ImGui.PopStyleColor(_ctx)
    end, Trap)

end

local function render_heading(text)
    Fonts.wrap(_ctx, Fonts.big, function()
        ImGui.SeparatorText(_ctx, text)
    end, Trap)
end

-- Center the next item horizontally within the current table cell.
local function center_next_item(item_width)
    local avail = ImGui.GetContentRegionAvail(_ctx)
    local indent = (avail - item_width) / 2
    if indent > 0 then
        ImGui.SetCursorPosX(_ctx, ImGui.GetCursorPosX(_ctx) + indent)
    end
end

-- Total width of an InputInt with its -/+ step buttons, given the desired
-- value-field width. Note SetNextItemWidth sets the TOTAL widget width and
-- InputInt carves the two buttons out of it, so we size and center by this.
local function int_input_total_width(field_width)
    local frame_h = ImGui.GetFrameHeight(_ctx)
    local spacing_x = ImGui.GetStyleVar(_ctx, ImGui.StyleVar_ItemInnerSpacing)
    return field_width + 2 * (frame_h + spacing_x)
end

local INT_FIELD_WIDTH = 44

local function render_centered_int_input(label, value, range)
    local total_width = int_input_total_width(INT_FIELD_WIDTH)
    center_next_item(total_width)
    ImGui.SetNextItemWidth(_ctx, total_width)
    local clamped = clamp_int(value, range.default, range.min, range.max)
    local changed, new_value = ImGui.InputInt(_ctx, label, clamped)
    if changed then
        return true, clamp_int(new_value, range.default, range.min, range.max)
    end
    -- Self-heal out-of-range persisted values: report the normalization as a
    -- change so it gets written back and saved.
    return clamped ~= value, clamped
end

local AXES = { 'x', 'y' }

-- Headers marked centered sit over cells whose content is also centered;
-- left-aligned columns (tree, Curve, Visibility) keep left headers.
local MAPPING_TABLE_COLUMNS = {
    { name = "",           flags = ImGui.TableColumnFlags_NoHide | ImGui.TableColumnFlags_WidthStretch, size = 3.0 },
    { name = "Axis",       flags = ImGui.TableColumnFlags_WidthFixed, size = 110, center = true },
    { name = "Curve",      flags = ImGui.TableColumnFlags_WidthFixed, size = 170 },
    { name = "Visibility", flags = ImGui.TableColumnFlags_WidthFixed, size = 120 },
    { name = "Thickness",  flags = ImGui.TableColumnFlags_WidthFixed, size = 120, center = true },
    { name = "Radius",     flags = ImGui.TableColumnFlags_WidthFixed, size = 120, center = true },
    { name = "Invert",     flags = ImGui.TableColumnFlags_WidthFixed, size = 70,  center = true },
    { name = "Bypass",     flags = ImGui.TableColumnFlags_WidthFixed, size = 70,  center = true },
    { name = "Remove",     flags = ImGui.TableColumnFlags_WidthFixed, size = 90,  center = true },
}

local function render_parameter_table_row(param_entry)
    local axis = param_entry.mappings.x and 'x'
        or param_entry.mappings.y and 'y'
        or nil

    if not axis then return end

    local m = param_entry.mappings[axis]
    local needs_save = false

    ImGui.TableNextRow(_ctx)

    -- column 0: tree leaf
    ImGui.TableSetColumnIndex(_ctx, 0)
    ImGui.PushID(_ctx, param_entry.param_number)
    Trap(function()
        local leaf_flags = ImGui.TreeNodeFlags_Leaf
            | ImGui.TreeNodeFlags_NoTreePushOnOpen
            | ImGui.TreeNodeFlags_SpanAvailWidth
            | ImGui.TreeNodeFlags_DefaultOpen
        if not ImGui.TreeNodeEx(_ctx, param_entry.param_number, param_entry.name, leaf_flags) then
            return
        end

        -- column 1: Axis radios (in-place reassign keeps curve settings and
        -- edit state; the mapping object's identity is preserved)
        ImGui.TableSetColumnIndex(_ctx, 1)
        local frame_h = ImGui.GetFrameHeight(_ctx)
        center_next_item(2 * (frame_h + ImGui.CalcTextSize(_ctx, "X")) + 24)
        for i, target in ipairs(AXES) do
            if i > 1 then ImGui.SameLine(_ctx) end
            if ImGui.RadioButton(_ctx, target:upper(), axis == target) and axis ~= target then
                mappings.reassign_axis(m, target)
            end
        end

        local call_result

        -- column 2: use curve + edit + color swatch
        ImGui.TableSetColumnIndex(_ctx, 2)
        call_result, m.use_curve = ImGui.Checkbox(_ctx, '##use_curve', m.use_curve ~= false)
        if call_result then
            m.use_curve = (m.use_curve ~= false)
            needs_save = true
        end

        ImGui.SameLine(_ctx)
        local edit_label = m.is_editing and 'Stop editing' or 'Edit curve'
        if ImGui.Button(_ctx, edit_label) then
            toggle_editing_mapping(axis, m)
        end

        ImGui.SameLine(_ctx)
        local color_flags = ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_NoLabel
        local new_color
        call_result, new_color = ImGui.ColorEdit4(_ctx, '##curve_color', m.curve_color, color_flags)
        if call_result then
            m.curve_color = new_color
            needs_save = true
        end

        -- column 3: visibility
        ImGui.TableSetColumnIndex(_ctx, 3)
        ImGui.SetNextItemWidth(_ctx, -1)
        local vis = m.curve_visibility
        if ImGui.BeginCombo(_ctx, '##curve_visibility', visibility_label(vis)) then
            Trap(function()
                call_result, vis.segments = ImGui.Checkbox(_ctx, 'segments', vis.segments)
                if call_result then needs_save = true end

                call_result, vis.points = ImGui.Checkbox(_ctx, 'points', vis.points)
                if call_result then needs_save = true end
            end)
            ImGui.EndCombo(_ctx)
        end

        -- column 4: thickness
        ImGui.TableSetColumnIndex(_ctx, 4)
        local new_thickness
        call_result, new_thickness = render_centered_int_input('##curve_thickness', m.curve_thickness, CURVE_THICKNESS)
        if call_result then
            m.curve_thickness = new_thickness
            needs_save = true
        end

        -- column 5: point radius
        ImGui.TableSetColumnIndex(_ctx, 5)
        local new_radius
        call_result, new_radius = render_centered_int_input('##curve_point_radius', m.curve_point_radius, CURVE_POINT_RADIUS)
        if call_result then
            m.curve_point_radius = new_radius
            needs_save = true
        end

        -- column 6: Invert
        ImGui.TableSetColumnIndex(_ctx, 6)
        center_next_item(frame_h)
        call_result, m.invert = ImGui.Checkbox(_ctx, '##invert', m.invert)
        if call_result then needs_save = true end

        -- column 7: Bypass
        ImGui.TableSetColumnIndex(_ctx, 7)
        center_next_item(frame_h)
        call_result, m.bypass = ImGui.Checkbox(_ctx, '##bypass', m.bypass)
        if call_result then needs_save = true end

        if needs_save then
            mappings.save_mappings()
        end

        -- column 8: Remove button
        ImGui.TableSetColumnIndex(_ctx, 8)
        center_next_item(ImGui.CalcTextSize(_ctx, "Remove") + 16)
        if ImGui.Button(_ctx, "Remove") then
            mappings.remove_mapping(m)
        end
    end)
    ImGui.PopID(_ctx)
end

local function render_fx_table_row(fx_entry)
    ImGui.TableNextRow(_ctx)
    ImGui.TableSetColumnIndex(_ctx, 0)

    local fx_open = ImGui.TreeNodeEx(_ctx, fx_entry.guid, fx_entry.name, ImGui.TreeNodeFlags_SpanAvailWidth | ImGui.TreeNodeFlags_DefaultOpen)
    if fx_open then
        Trap(function()
            for _, param_entry in ipairs(fx_entry.params or {}) do
                render_parameter_table_row(param_entry)
            end
        end)
        ImGui.TreePop(_ctx)
    end
end

local function render_track_table_row(track_entry)
    ImGui.TableNextRow(_ctx)
    ImGui.TableSetColumnIndex(_ctx, 0)

    Trap(function()
        local track_open = ImGui.TreeNodeEx(_ctx, track_entry.guid, track_entry.name, ImGui.TreeNodeFlags_SpanAvailWidth | ImGui.TreeNodeFlags_DefaultOpen)

        if track_open then
            Trap(function()
                for _, fx_entry in ipairs(track_entry.fx or {}) do
                    render_fx_table_row(fx_entry)
                end
            end)
            ImGui.TreePop(_ctx)
        end
    end)
end

local function render_mapping_tree_table(ms_table)
    local table_flags = ImGui.TableFlags_Borders
        | ImGui.TableFlags_NoSavedSettings
        | ImGui.TableFlags_RowBg
        | ImGui.TableFlags_Resizable
        | ImGui.TableFlags_ScrollY
    if ImGui.BeginTable(_ctx, "mappings-table", #MAPPING_TABLE_COLUMNS, table_flags) then
        Trap(function()
            for _, col in ipairs(MAPPING_TABLE_COLUMNS) do
                ImGui.TableSetupColumn(_ctx, col.name, col.flags, col.size)
            end

            ImGui.TableNextRow(_ctx, ImGui.TableRowFlags_Headers)
            for i, col in ipairs(MAPPING_TABLE_COLUMNS) do
                ImGui.TableSetColumnIndex(_ctx, i - 1)
                if col.name ~= "" then
                    if col.center then
                        center_next_item(ImGui.CalcTextSize(_ctx, col.name))
                    end
                    ImGui.Text(_ctx, col.name)
                end
            end

            for _, track_entry in ipairs(ms_table.tracks or {}) do
                render_track_table_row(track_entry)
            end
        end)
        ImGui.EndTable(_ctx)
    end
end

local function render_mapping()
    if not mappings_open then
        return
    end

    local parameter_window_flags
        = ImGui.WindowFlags_NoDocking
        | ImGui.WindowFlags_NoSavedSettings
        | ImGui.WindowFlags_NoCollapse

    ImGui.SetNextWindowSize(_ctx, DEFAULT_MAPPINGS_WINDOW_WIDTH, DEFAULT_MAPPINGS_WINDOW_HEIGHT, ImGui.Cond_FirstUseEver)

    local visible, open = ImGui.Begin(_ctx, 'Mappings', true, parameter_window_flags)
    if visible then
        Trap(function()
            if not open then
                mappings_open = false
            end

            Fonts.wrap(_ctx, Fonts.main, function()
                if mappings.is_empty() then
                    Fonts.wrap(_ctx, Fonts.big, function()
                        ImGui.Text(_ctx, 'No mappings')
                    end, Trap)
                else
                    local ms = mappings.get_mappings()

                    render_mapping_tree_table(ms.ms_table)
                end
            end, Trap)
        end)
        ImGui.End(_ctx)
    end

end

local function render_grid_options(options)
    render_heading('Grid Options')

    local imgui_result;
    local needs_save = false

    local link_xy = options.grid_lines_linked
    imgui_result, link_xy = ImGui.Checkbox(_ctx, 'Link X/Y Grid Lines', link_xy)

    if imgui_result then
        options.grid_lines_linked = link_xy
        needs_save = true
    end

    local x_lines = options.x_lines
    imgui_result, x_lines = ImGui.SliderInt(_ctx, 'x-axis', x_lines, 0, 10, "%d")
    if imgui_result then
        options.x_lines = x_lines

        if link_xy then
            options.y_lines = x_lines
        end

        needs_save = true
    end

    local y_lines = options.y_lines
    imgui_result, y_lines = ImGui.SliderInt(_ctx, 'y-axis', y_lines, 0, 10, "%d")
    if imgui_result then
        options.y_lines = y_lines

        if link_xy then
            options.x_lines = y_lines
        end

        needs_save = true
    end

    ImGui.Spacing(_ctx)

    local grid_lines_linked_color = options.grid_lines_linked_color
    imgui_result, grid_lines_linked_color = ImGui.Checkbox(_ctx, 'Link Grid Line Colors', grid_lines_linked_color)
    if imgui_result then
        options.grid_lines_linked_color = grid_lines_linked_color
        needs_save = true
    end

    local grid_line_x_color = options.grid_line_x_color
    imgui_result, grid_line_x_color = ImGui.ColorEdit4(_ctx, 'X Grid Line Color', grid_line_x_color)
    if imgui_result then
        options.grid_line_x_color = grid_line_x_color

        if grid_lines_linked_color then
            options.grid_line_y_color = grid_line_x_color
        end

        needs_save = true
    end

    local grid_line_y_color = options.grid_line_y_color
    imgui_result, grid_line_y_color = ImGui.ColorEdit4(_ctx, 'Y Grid Line Color', grid_line_y_color)
    if imgui_result then
        options.grid_line_y_color = grid_line_y_color

        if grid_lines_linked_color then
            options.grid_line_x_color = grid_line_y_color
        end

        needs_save = true
    end

    local grid_line_width = options.grid_line_width
    imgui_result, grid_line_width = ImGui.SliderDouble(_ctx, 'Grid Line Width', grid_line_width, 1.0, 5.0, "%.2f")
    if imgui_result then
        options.grid_line_width = grid_line_width
        needs_save = true
    end

    return needs_save
end

local function render_pad_options(options)
    render_heading('Pad Options')

    local imgui_result;
    local needs_save = false

    local pad_bg_color = options.pad_bg_color
    imgui_result, pad_bg_color = ImGui.ColorEdit4(_ctx, 'Pad Background Color', pad_bg_color)
    if imgui_result then
        options.pad_bg_color = pad_bg_color
        needs_save = true
    end

    local pad_label_color = options.pad_label_color
    imgui_result, pad_label_color = ImGui.ColorEdit4(_ctx, 'Pad Label Color', pad_label_color)
    if imgui_result then
        options.pad_label_color = pad_label_color
        needs_save = true
    end

    return needs_save
end

local function render_cursor_options(options)
    render_heading('Cursor Options')

    local imgui_result;
    local needs_save = false

    local cursor_color = options.cursor_color
    imgui_result, cursor_color = ImGui.ColorEdit4(_ctx, 'Cursor Color', cursor_color)
    if imgui_result then
        options.cursor_color = cursor_color
        needs_save = true
    end

    local cursor_radius = options.cursor_radius
    imgui_result, cursor_radius = ImGui.SliderInt(_ctx, 'Cursor Radius', cursor_radius, 1, 25, "%d")
    if imgui_result then
        options.cursor_radius = cursor_radius
        needs_save = true
    end

    local cursor_stroke = options.cursor_stroke
    imgui_result, cursor_stroke = ImGui.SliderInt(_ctx, 'Cursor Stroke', cursor_stroke, 1, 4, "%d")
    if imgui_result then
        options.cursor_stroke = cursor_stroke
        needs_save = true
    end

    return needs_save
end

local function render_curve_options(options)
    render_heading('Curve Options')

    local needs_save = false
    local imgui_result

    local transpose = options.transpose_y_curve ~= false
    imgui_result, transpose = ImGui.Checkbox(_ctx, 'Transpose Y curve', transpose)
    if imgui_result then
        options.transpose_y_curve = transpose
        needs_save = true
    end

    return needs_save
end

local function render_options(frame)
    if not options_open then
        return
    end

    local options = frame.options

    local options_window_flags
        = ImGui.WindowFlags_NoDocking
        | ImGui.WindowFlags_AlwaysAutoResize
        | ImGui.WindowFlags_NoCollapse

    local visible, open = ImGui.Begin(_ctx, 'Options', true, options_window_flags)
    if visible then
        Trap(function()
            if not open then
                options_open = false
            end

            local needs_save = false

            for _, renderer in ipairs {
                render_pad_options,
                render_grid_options,
                render_cursor_options,
                render_curve_options,
            } do
                if renderer(options) then
                    needs_save = true
                end

                ImGui.Spacing(_ctx)
                ImGui.Spacing(_ctx)
                ImGui.Spacing(_ctx)
            end

            if needs_save then
                config.save_config(options)
            end
        end)
        ImGui.End(_ctx)
    end
end

local function ctx()
    if ImGui.ValidatePtr(_ctx, 'ImGui_Context*') then
        return _ctx
    end

    _ctx = ImGui.CreateContext(IMGUI_CONTEXT_NAME)

    Fonts:init(_ctx, STORAGE_SECTION)

    return _ctx
end

local function create_frame_context(options)
    return {
        ctx = _ctx,
        fonts = Fonts:check(_ctx),
        options = options,
    }
end

mappings.on_add_mapping(function()
    if not mappings_open then
        mappings_open = true
    end
end)

local function render(options)
    transpose_y_curve = options.transpose_y_curve ~= false

    xy_menu_bar()

    local frame = create_frame_context(options)

    if default_help_open and not mappings.is_empty() then
        mappings_open = true
        default_help_open = false
    end

    default_help_open = mappings.is_empty()

    if ImGui.IsKeyPressed(_ctx, ImGui.Key_X) then
        training.train('x', mappings)
    end

    if ImGui.IsKeyPressed(_ctx, ImGui.Key_Y) then
        training.train('y', mappings)
    end

    -- Observe external project changes BEFORE the pad renders: a drag's own
    -- param writes re-arm the change watermark, so a check that runs after
    -- them would silently absorb any external change from the same frame.
    if mappings_open then
        mappings.refresh_if_project_changed()
    end

    if training.is_training() then
        training.render(frame, mappings)
    elseif help_open or default_help_open then
        help.render(frame)
    else
        render_xy_pad(frame)
    end
    render_mapping()
    render_options(frame)
end

return {
    ctx = ctx,
    render = render,
}