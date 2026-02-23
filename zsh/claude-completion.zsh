#compdef claude

_claude() {
  local curcontext="$curcontext" state line
  typeset -A opt_args

  _arguments -C \
    '--add-dir[Additional directories to allow tool access to]:directories:_files -/' \
    '--agent[Agent for the current session]:agent:' \
    '--agents[JSON object defining custom agents]:json:' \
    '--allow-dangerously-skip-permissions[Enable bypassing all permission checks as an option]' \
    '(--allowedTools --allowed-tools)'{--allowedTools,--allowed-tools}'[Comma or space-separated list of tool names to allow]:tools:' \
    '--append-system-prompt[Append to the default system prompt]:prompt:' \
    '--betas[Beta headers to include in API requests]:betas:' \
    '--chrome[Enable Claude in Chrome integration]' \
    '(-c --continue)'{-c,--continue}'[Continue the most recent conversation]' \
    '--dangerously-skip-permissions[Bypass all permission checks]' \
    '(-d --debug)'{-d,--debug}'[Enable debug mode with optional category filtering]::filter:' \
    '--debug-file[Write debug logs to a file]:path:_files' \
    '--disable-slash-commands[Disable all skills]' \
    '(--disallowedTools --disallowed-tools)'{--disallowedTools,--disallowed-tools}'[Comma or space-separated list of tool names to deny]:tools:' \
    '--effort[Effort level for the current session]:level:(low medium high)' \
    '--fallback-model[Fallback model when default is overloaded]:model:' \
    '--file[File resources to download at startup]:specs:_files' \
    '--fork-session[Create a new session ID when resuming]' \
    '--from-pr[Resume a session linked to a PR]::pr number or url:' \
    '(-h --help)'{-h,--help}'[Display help]' \
    '--ide[Auto-connect to IDE on startup]' \
    '--include-partial-messages[Include partial message chunks as they arrive]' \
    '--input-format[Input format]:format:(text stream-json)' \
    '--json-schema[JSON Schema for structured output validation]:schema:' \
    '--max-budget-usd[Maximum dollar amount for API calls]:amount:' \
    '--mcp-config[Load MCP servers from JSON files or strings]:configs:_files' \
    '--mcp-debug[Enable MCP debug mode (deprecated)]' \
    '--model[Model for the current session]:model:(sonnet opus haiku)' \
    '--no-chrome[Disable Claude in Chrome integration]' \
    '--no-session-persistence[Disable session persistence]' \
    '--output-format[Output format]:format:(text json stream-json)' \
    '--permission-mode[Permission mode for the session]:mode:(acceptEdits bypassPermissions default dontAsk plan)' \
    '--plugin-dir[Load plugins from directories]:paths:_files -/' \
    '(-p --print)'{-p,--print}'[Print response and exit]' \
    '--replay-user-messages[Re-emit user messages from stdin back on stdout]' \
    '(-r --resume)'{-r,--resume}'[Resume a conversation by session ID]::session id:' \
    '--session-id[Use a specific session ID]:uuid:' \
    '--setting-sources[Setting sources to load]:sources:' \
    '--settings[Path to settings JSON file or JSON string]:file-or-json:_files' \
    '--strict-mcp-config[Only use MCP servers from --mcp-config]' \
    '--system-prompt[System prompt for the session]:prompt:' \
    '--tmux[Create a tmux session for the worktree]' \
    '--tools[Specify available tools from the built-in set]:tools:' \
    '--verbose[Override verbose mode setting from config]' \
    '(-v --version)'{-v,--version}'[Output the version number]' \
    '(-w --worktree)'{-w,--worktree}'[Create a new git worktree for this session]::name:' \
    '1: :_claude_commands' \
    '*::arg:->args'

  case $state in
    args)
      case $words[1] in
        mcp)
          _arguments -C \
            '(-h --help)'{-h,--help}'[Display help]' \
            '1: :_claude_mcp_commands' \
            '*::arg:->mcp_args'
          case $state in
            mcp_args)
              case $words[1] in
                add)
                  _arguments \
                    '(-s --scope)'{-s,--scope}'[Scope]:scope:(user project local)' \
                    '(-t --transport)'{-t,--transport}'[Transport type]:transport:(stdio http)' \
                    '(-e --env)'{-e,--env}'[Environment variables]:env:' \
                    '--header[HTTP headers]:header:' \
                    '(-h --help)'{-h,--help}'[Display help]' \
                    '1:name:' \
                    '2:command or url:_files'
                  ;;
                add-json)
                  _arguments \
                    '(-s --scope)'{-s,--scope}'[Scope]:scope:(user project local)' \
                    '(-h --help)'{-h,--help}'[Display help]' \
                    '1:name:' \
                    '2:json:'
                  ;;
                remove)
                  _arguments \
                    '(-s --scope)'{-s,--scope}'[Scope]:scope:(user project local)' \
                    '(-h --help)'{-h,--help}'[Display help]' \
                    '1:name:'
                  ;;
                get|list|reset-project-choices|serve|add-from-claude-desktop)
                  _arguments '(-h --help)'{-h,--help}'[Display help]'
                  ;;
              esac
              ;;
          esac
          ;;
        auth)
          _arguments -C \
            '(-h --help)'{-h,--help}'[Display help]' \
            '1: :_claude_auth_commands' \
            '*::arg:->auth_args'
          case $state in
            auth_args)
              _arguments '(-h --help)'{-h,--help}'[Display help]'
              ;;
          esac
          ;;
        plugin)
          _arguments -C \
            '(-h --help)'{-h,--help}'[Display help]' \
            '1: :_claude_plugin_commands' \
            '*::arg:->plugin_args'
          case $state in
            plugin_args)
              _arguments '(-h --help)'{-h,--help}'[Display help]'
              ;;
          esac
          ;;
        install)
          _arguments \
            '--force[Force installation even if already installed]' \
            '(-h --help)'{-h,--help}'[Display help]' \
            '1:target:(stable latest)'
          ;;
        agents)
          _arguments \
            '(-h --help)'{-h,--help}'[Display help]' \
            '--setting-sources[Setting sources to load]:sources:'
          ;;
        doctor|setup-token|update|upgrade)
          _arguments '(-h --help)'{-h,--help}'[Display help]'
          ;;
      esac
      ;;
  esac
}

_claude_commands() {
  local -a commands=(
    'agents:List configured agents'
    'auth:Manage authentication'
    'doctor:Check auto-updater health'
    'install:Install Claude Code native build'
    'mcp:Configure and manage MCP servers'
    'plugin:Manage Claude Code plugins'
    'setup-token:Set up a long-lived authentication token'
    'update:Check for updates and install if available'
  )
  _describe -t commands 'command' commands
}

_claude_mcp_commands() {
  local -a commands=(
    'add:Add an MCP server'
    'add-from-claude-desktop:Import MCP servers from Claude Desktop'
    'add-json:Add an MCP server with a JSON string'
    'get:Get details about an MCP server'
    'list:List configured MCP servers'
    'remove:Remove an MCP server'
    'reset-project-choices:Reset approved/rejected project-scoped servers'
    'serve:Start the Claude Code MCP server'
  )
  _describe -t commands 'mcp command' commands
}

_claude_auth_commands() {
  local -a commands=(
    'login:Sign in to your Anthropic account'
    'logout:Log out from your Anthropic account'
    'status:Show authentication status'
  )
  _describe -t commands 'auth command' commands
}

_claude_plugin_commands() {
  local -a commands=(
    'disable:Disable an enabled plugin'
    'enable:Enable a disabled plugin'
    'install:Install a plugin from available marketplaces'
    'list:List installed plugins'
    'marketplace:Manage Claude Code marketplaces'
    'uninstall:Uninstall an installed plugin'
    'update:Update a plugin to the latest version'
    'validate:Validate a plugin or marketplace manifest'
  )
  _describe -t commands 'plugin command' commands
}

compdef _claude claude
