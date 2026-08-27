#!/bin/sh

set -eu

DOTFILES_ROOT="$HOME/.dotfiles"
CODEX_EXCLUSIONS="$DOTFILES_ROOT/ai/codex/excluded-skills.txt"

# shellcheck source=/dev/null
. "$DOTFILES_ROOT/ai/helpers/output.sh"
# shellcheck source=/dev/null
. "$DOTFILES_ROOT/ai/helpers/managed-links.sh"
# shellcheck source=/dev/null
. "$DOTFILES_ROOT/ai/helpers/excluded-skills.sh"
# shellcheck source=/dev/null
. "$DOTFILES_ROOT/ai/mcp-servers.sh"

UNINSTALL=false
INSTALL_INSTRUCTIONS=true
INSTALL_AGENTS=true
INSTALL_SKILLS=true
INSTALL_MCP=true

show_help() {
	echo "Usage: $0 [OPTIONS]"
	echo ""
	echo "Install Codex instructions, agents, skills, and MCP servers."
	echo ""
	echo "  --uninstall          Remove managed file-based configuration"
	echo "  --instructions-only  Install only AGENTS.md"
	echo "  --agents-only        Install only custom agents"
	echo "  --skills-only        Install only skills"
	echo "  --mcp-only           Install only MCP servers"
	echo "  --no-instructions    Skip AGENTS.md"
	echo "  --no-agents          Skip custom agents"
	echo "  --no-skills          Skip skills"
	echo "  --no-mcp             Skip MCP servers"
}

select_only() {
	INSTALL_INSTRUCTIONS=false
	INSTALL_AGENTS=false
	INSTALL_SKILLS=false
	INSTALL_MCP=false
}

while [ $# -gt 0 ]; do
	case "$1" in
	--uninstall) UNINSTALL=true ;;
	--instructions-only)
		select_only
		INSTALL_INSTRUCTIONS=true
		;;
	--agents-only)
		select_only
		INSTALL_AGENTS=true
		;;
	--skills-only)
		select_only
		INSTALL_SKILLS=true
		;;
	--mcp-only)
		select_only
		INSTALL_MCP=true
		;;
	--no-instructions) INSTALL_INSTRUCTIONS=false ;;
	--no-agents) INSTALL_AGENTS=false ;;
	--no-skills) INSTALL_SKILLS=false ;;
	--no-mcp) INSTALL_MCP=false ;;
	# Claude-only skip flags; ai/install.sh forwards every flag to both installers.
	--no-claude-md | --no-hooks | --no-permissions) ;;
	-h | --help)
		show_help
		exit 0
		;;
	*)
		echo "Unknown option: $1"
		show_help
		exit 1
		;;
	esac
	shift
done

remove_managed_skill_links() {
	[ -d "$HOME/.agents/skills" ] || return 0
	for link in "$HOME"/.agents/skills/*; do
		[ -L "$link" ] || continue
		case "$(readlink "$link")" in
		"$DOTFILES_ROOT"/ai/skills/*) rm -f "$link" ;;
		esac
	done
}

# Must match MANAGED_HEADER in ai/bin/render-codex-agents.py. If the two drift, a
# managed regular file stops being recognized as ours, install_managed_link sees a
# plain file and skips it, and that agent never updates again.
MANAGED_AGENT_HEADER="# Managed by ~/.dotfiles/ai/install-codex.sh."

remove_managed_agents() {
	[ -d "$HOME/.codex/agents" ] || return 0
	for agent in "$HOME"/.codex/agents/*.toml; do
		[ -e "$agent" ] || [ -L "$agent" ] || continue
		if [ -L "$agent" ]; then
			case "$(readlink "$agent")" in
			"$HOME"/.codex/.dotfiles-agents/* | "$HOME"/.codex/agents/.dotfiles/*) rm -f "$agent" ;;
			esac
		elif [ "$(head -n 1 "$agent")" = "$MANAGED_AGENT_HEADER" ]; then
			rm -f "$agent"
		fi
	done
}

if [ "$UNINSTALL" = "true" ]; then
	info "Uninstalling Codex configuration…"
	if [ "$INSTALL_INSTRUCTIONS" = "true" ] && [ -L "$HOME/.codex/AGENTS.md" ] && [ "$(readlink "$HOME/.codex/AGENTS.md")" = "$DOTFILES_ROOT/ai/AGENTS.md" ]; then
		rm -f "$HOME/.codex/AGENTS.md"
	fi
	if [ "$INSTALL_SKILLS" = "true" ]; then remove_managed_skill_links; fi
	if [ "$INSTALL_AGENTS" = "true" ]; then
		remove_managed_agents
		rm -rf "$HOME/.codex/.dotfiles-agents" "$HOME/.codex/agents/.dotfiles"
	fi
	success "Codex configuration uninstalled successfully!"
	info "MCP servers are not removed by uninstall"
	exit 0
fi

info "Installing Codex configuration…"
mkdir -p "$HOME/.codex"

if [ "$INSTALL_INSTRUCTIONS" = "true" ]; then
	if install_managed_link "$DOTFILES_ROOT/ai/AGENTS.md" "$HOME/.codex/AGENTS.md" "$DOTFILES_ROOT/ai/"; then
		success "Installed AGENTS.md"
	else
		info "Move or delete $HOME/.codex/AGENTS.md and re-run to use the shared instructions."
	fi
fi

if [ "$INSTALL_SKILLS" = "true" ]; then
	mkdir -p "$HOME/.agents/skills"
	# Relink from scratch so a skill that was removed from the repo, or newly added to
	# excluded-skills.txt, stops being linked on an existing install.
	remove_managed_skill_links
	shadowed_skills=""
	for skill_dir in "$DOTFILES_ROOT"/ai/skills/*/; do
		[ -d "$skill_dir" ] || continue
		skill_name=$(basename "$skill_dir")
		destination="$HOME/.agents/skills/$skill_name"
		if is_excluded_skill "$skill_name" "$CODEX_EXCLUSIONS"; then
			# remove_managed_skill_links only removes symlinks, so an excluded skill that
			# predates the exclusion survives as a real directory and Codex keeps loading it.
			if [ -e "$destination" ] || [ -L "$destination" ]; then
				warning "$skill_name is excluded from Codex but $destination still exists; remove it by hand"
			fi
		elif ! install_managed_link "$skill_dir" "$destination" "$DOTFILES_ROOT/ai/skills/"; then
			shadowed_skills="$shadowed_skills $skill_name"
		fi
	done
	if [ -n "$shadowed_skills" ]; then
		error "Not linked, a directory already occupies the destination:$shadowed_skills"
		info "Move or delete those directories under $HOME/.agents/skills, then re-run."
	else
		success "Symlinked Codex-compatible skills"
	fi
fi

if [ "$INSTALL_AGENTS" = "true" ]; then
	# Codex scans ~/.codex/agents recursively and does not skip dot-directories, so
	# staging the rendered TOML in there would register every agent twice.
	generated_agents="$HOME/.codex/.dotfiles-agents"
	mkdir -p "$generated_agents" "$HOME/.codex/agents"
	# Render before removing, so a renderer failure under `set -e` leaves the previously
	# installed agents in place instead of an empty directory. The removal still has to
	# precede the relink loop, or a leftover managed regular file makes
	# install_managed_link skip its destination.
	python3 "$DOTFILES_ROOT/ai/bin/render-codex-agents.py" "$DOTFILES_ROOT/ai/agents" "$generated_agents"
	remove_managed_agents
	# Installs made before the staging move left a directory Codex would scan.
	rm -rf "$HOME/.codex/agents/.dotfiles"
	shadowed_agents=""
	for agent in "$generated_agents"/*.toml; do
		[ -f "$agent" ] || continue
		agent_name=$(basename "$agent")
		destination="$HOME/.codex/agents/$agent_name"
		if ! install_managed_link "$agent" "$destination" "$generated_agents/"; then
			shadowed_agents="$shadowed_agents $agent_name"
		fi
	done
	if [ -n "$shadowed_agents" ]; then
		error "Not linked, a file already occupies the destination:$shadowed_agents"
	else
		success "Installed Codex custom agents"
	fi
fi

if [ "$INSTALL_MCP" = "true" ]; then
	if ! command -v codex >/dev/null 2>&1; then
		warning "Codex CLI not found; skipping MCP servers"
	else
		installed_servers=$(codex mcp list --json 2>/dev/null || echo '[]')
		echo "$MCP_SERVERS" | grep -v '^$' | while IFS='|' read -r name transport description target; do
			[ -n "$name" ] || continue
			if echo "$installed_servers" | grep -q "\"$name\""; then
				success "$description already installed"
			elif [ "$transport" = "stdio" ] && ! stdio_command_available "${target%% *}"; then
				warning "$description skipped: ${target%% *} not found"
			elif [ "$transport" = "http" ]; then
				if codex mcp add "$name" --url "$target"; then
					success "$description installed"
				else
					error "$description failed to install"
				fi
			else
				# Intentional field splitting turns environment and command strings into arguments.
				# shellcheck disable=SC2046,SC2086
				if codex mcp add "$name" $(set_codex_server_env "$name") -- $target; then
					success "$description installed"
				else
					error "$description failed to install"
				fi
			fi
		done
	fi
fi

echo ""
success "Codex configuration installed successfully!"
