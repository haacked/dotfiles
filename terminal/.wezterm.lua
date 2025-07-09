-- Pull in the wezterm API
local wezterm = require 'wezterm'

-- This will hold the configuration.
local config = wezterm.config_builder()

-- This is where you actually apply your config choices.
config.default_cursor_style = 'BlinkingBar'
config.font_size = 16
config.font = wezterm.font('JetBrains Mono')

-- Transparency
config.window_background_opacity = 0.9
config.enable_tab_bar = false

-- Colors
config.color_scheme = 'Bamboo'

-- Finally, return the configuration to wezterm:
return config