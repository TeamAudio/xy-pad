# XY Pad

### Overview
XY Pad, by [Tech Audio](https://techaud.io/), is an interactive control script that can map and manipulate plugin parameters across an XY Pad.

- [Prerequisites](#prerequisites)
- [Main Scripts](#main-scripts)
- [UI Layout](#ui-layout)
    - [XY Pad Window](#xy-pad-window)
    - [Mappings Window](#mappings-window)
    - [Options Window](#options-window)
- [How To Use](#how-to-use)
    - [Mapping Parameters](#mapping-parameters)
    - [Manipulate Parameters](#manipulate-parameters)
    - [Customizing Parameter Manipulation Power](#customizing-parameter-manipulation-power)

### Prerequisites
- [ReaImGui API](https://github.com/cfillion/reaimgui) available via ReaPack

### Main Scripts
XY Pad consists of a main control script, and 3 component scripts:
- TA_XY Pad.lua
    - Main control script. Renders the `XY Pad` and `Mappings` windows
- TA_XY Pad Set X.lua
    - Links last touched plugin parameter to the X axis
- TA_XY Pad Set Y.lua
    - Links last touched plugin parameter to the Y axis
- TA_XY Pad Full Reset.lua
    - Deletes all saved mappings and resets `TA_XY Pad.lua` to an initial state

## UI Layout
### XY Pad Window
This is where you control parameters you've mapped to the pad by clicking and dragging your cursor within the grid boundaries. Parameters mapped to the X axis will have their values determined based on a factor ranging between 0 on the left edge and 1 on the right. Parameters mapped to the Y axis work similarly, with 0 at the bottom edge and 1 at the top.

![XY Pad Main Window](/Manuals/xy-pad/window_main.png)
- Main menu items
    - `Mappings`
        - `Show/Hide Mappings` opens the `Mappings` window
        - `New Mapping` submenu items to map plugin parameters to the X or Y axis
    - `Show/Hide Options`
        - Opens and closes the `Options` window to change the colors, grid setup, and other appearance settings of XY Pad
    - `Show/Hide Help`
        - Shows and hides the tutorial text that is shown on first startup
### Mappings Window
This window lets you monitor which parameters are mapped, edit the range of the XY Pad, invert the controls, or bypass controls entirely.

![XY Pad Mapping Window](/Manuals/xy-pad/window_mappings.png)
- Available mapping options
    - `Max/Min` Sliders
        - Changes the range of values that XY Pad sends to plugin parameters
    - `Invert`
        - Inverts values from XY Pad, with respect to the `Max/Min` sliders
    - `Bypass`
        - Bypasses the selected plugin parameter from being affected by XY Pad
### Options Window
Here, you can change aesthetic properties of XY Pad. Number of gridlines, colors, just about everything!

![XY Pad Options Window](/Manuals/xy-pad/window_options.png)
- Pad Options
    - Change the pad background color and the pad's lower-left corner label color
- Grid Options
    - Change the number of horizontal and vertical gridlines that occupy the pad
        - `Link X/Y Grid Lines` change values at the same time
    - Change gridline colors
        - `Link Grid Line Colors`
    - Change gridline width
        - Change thickness of the gridlines
- Cursor Options
    - `Cursor Color`
        - Change the color of the circular cursor that shows when clicking and dragging on the pad
    - `Cursor Radius`
        - Change the size of the circular cursor
    - `Cursor Stroke`
        - Change the thickness of the circular cursor

## How to Use
### Mapping Parameters
XY Pad allows you to map a parameter by running one of its accessory actions (TA_XY Pad Set X.lua and TA_XY Pad Set Y.lua) or by activating a training mode directly inside of the plugin.

If you'd like to map a global shortcut to assign parameters to the pad, use one of the accessory scripts:

1. Click on the plugin parameter you'd like to assign to the pad.
2. With the main TA_XY Pad.lua running, run either the TA_XY Pad Set X.lua or TA_XY Pad Set Y.lua action to map that parameter to the X or Y axis respectively.

If you'd prefer to do this from XY Pad directly, you can!

1. Invoke the training mode from the main window by selecting New Mapping -> Map to X Axis or New Mapping -> Map to Y Axis from the Mappings menu. Keyboard shortcuts "x" and "y" are also available to trigger the same behavior.
2. Click on the plugin parameter you'd like to assign to the pad.

You should see your mapped parameter appear in the Mappings window under the chosen axis.

Both modes leverage REAPER's GetTouchedOrFocusedFX() ReaScript function to determine the last parameter that you interacted with. This can be a somewhat quirky experience in practice, for example if you've already mapped a parameter and attempt to map it again. XY Pad will do its best in training mode to describe any situation preventing a mapping based on this value, displaying messages like "No tracks in project", "No FX in project" or "Touch an unmapped parameter to map it to the pad."
### Manipulate Parameters
- On the main `XY Pad` window, values (0, 0) is the bottom left corner, and (1, 1) is the top right corner
- Clicking and dragging your mouse across the Pad will move the plugin parameters between the **minimum-most** value and **maximum-most** value *for that particular plugin* by default
    - You can customize these values in the next section
### Customizing Parameter Manipulation Power
- `Max` and `Min` sliders limit the values that XY Pad imparts on the plugin's parameter from a scale of `0.00` to `1.00`
    - You can `CTRL + CLICK` (`CMD + CLICK` on MacOS) on the slider to input your own value
- `Invert` checkbox swaps the baseline values of XY Pad, as described earlier, meaning (0, 0) is now the ***top-right*** corner, and (1, 1) is the ***bottom-left*** corner, while also respecting the `Max` and `Min` sliders
- `Bypass` checkbox switches on and off the manipulation of the plugin's parameter by the XY Pad
