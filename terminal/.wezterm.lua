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

-- Key bindings for Claude Code
config.keys = {
  {
    key = 'Enter',
    mods = 'SHIFT',
    action = wezterm.action.SendString '\n',
  },
}

-- Links
-- Define a custom opener for file paths
wezterm.on('open-uri', function(window, pane, uri)
  local start, match_end = uri:find('file://localhost/')
  if start == 1 then
    uri = 'file://' .. uri:sub(match_end)
  end
  
  if uri:sub(1, 7) == 'file://' then
    local path = uri:sub(8)
    -- Handle relative paths by making them absolute
    if not path:match('^/') then
      local cwd = pane:get_current_working_dir()
      if cwd then
        path = cwd.file_path .. '/' .. path
      end
    end
    
    -- Open the file with the system's default application
    wezterm.open_with(path)
    
    -- Prevent the default action
    return false
  end
end)

config.hyperlink_rules = wezterm.default_hyperlink_rules()

-- Add custom rule for code files
table.insert(config.hyperlink_rules, {
  -- Match file paths with common code/text extensions
  -- Works with git output, logs, and general file references
  -- Supports: foo.cs, path/to/file.py, ../relative/path.js, ./local.tsx
  regex = [[((?:\.{0,2}/)?(?:[\w.-]+/)*[\w.-]+\.(?:cs|py|ts|js|jsx|tsx|json|xml|yaml|yml|md|txt|sh|bash|zsh|fish|ps1|psm1|psd1|rb|go|rs|java|kt|swift|cpp|cc|cxx|c|h|hpp|php|html|css|scss|sass|less|sql|r|R|lua|vim|el|clj|cljs|edn|scala|sbt|fs|fsx|fsi|ml|mli|ex|exs|erl|hrl|zig|zig\.zon|nim|v|dart|pl|pm|t|asm|s|S|pas|pp|inc|cfg|conf|config|ini|toml|lock|env|gitignore|dockerignore|dockerfile|Dockerfile|makefile|Makefile|cmake|mk|am|in|out|log))]],
  format = "file://$1",
})

-- Finally, return the configuration to wezterm:
return config
