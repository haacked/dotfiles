# Analyze Claude Code Permissions

Analyze accumulated permissions in `settings.local.json` and suggest smart wildcard patterns to add to the shared configuration.

## Arguments (parsed from user input)

- **action**: What to do - `analyze` (default), `apply`, or `cleanup`

Example invocations:

- `/analyze-permissions` → analyze and suggest patterns
- `/analyze-permissions apply` → apply suggested patterns to shared config
- `/analyze-permissions cleanup` → just run the cleanup script

## Your Task

### Step 1: Read Current Permissions

Read both settings files:

1. `~/.claude/settings.local.json` - accumulated "Always allow" permissions
2. `~/.claude/settings.json` - shared/base permissions from configure-tool-permissions.sh

Also read the shared config script to understand what's managed:
- `~/.dotfiles/ai/configure-tool-permissions.sh`

### Step 2: Analyze Patterns

For each entry in `settings.local.json`:

1. **Check if already covered** - Is there a wildcard in `settings.json` that covers this?
   - `Bash(git commit -m "Fix bug")` is covered by `Bash(git commit:*)`
   - `Bash(curl https://api.example.com)` is covered by `Bash(curl:*)`

2. **Identify pattern opportunities** - Group similar commands:
   - Multiple `kubectl` commands → suggest `Bash(kubectl:*)`
   - Multiple `docker` commands → suggest `Bash(docker:*)`
   - Multiple WebFetch for same domain → suggest `WebFetch(https://example.com/*)`

3. **Assess safety** - Consider if the pattern is safe for auto-approval:
   - Read-only commands: Generally safe
   - Commands with side effects: Flag for review
   - Overly broad patterns: Warn about security implications

### Step 3: Present Analysis

Output a structured report:

```
## Permission Analysis

### Settings Overview
- settings.local.json: X entries
- settings.json: Y entries (Z wildcards)

### Already Covered (can be removed)
These entries in settings.local.json are redundant:

| Entry | Covered by |
|-------|------------|
| Bash(git commit -m "...") | Bash(git commit:*) |

### Suggested New Patterns
These patterns would consolidate multiple specific entries:

| Pattern | Covers | Safety |
|---------|--------|--------|
| Bash(kubectl:*) | 4 entries | ✅ Safe (read-heavy) |
| Bash(docker exec:*) | 3 entries | ⚠️ Review (can modify) |

### Uncategorized
These entries don't fit a pattern (one-offs):

- Bash(some-specific-command)
```

### Step 4: Handle Actions

Based on the action argument:

**analyze (default):**
- Present the report
- Ask if user wants to apply suggestions

**apply:**
- For each suggested pattern, ask for confirmation
- Add approved patterns to `configure-tool-permissions.sh` in the PERMISSIONS_CONFIG section
- Run the cleanup script to remove now-redundant entries

**cleanup:**
- Just run `~/.dotfiles/ai/bin/cleanup-settings-local.sh`

### Step 5: Update Shared Config (if applying)

When adding patterns to `configure-tool-permissions.sh`:

1. Add new entries to the `PERMISSIONS_CONFIG` JSON array
2. Add corresponding check to the validation section (the long `if` statement)
3. Run the script to apply changes: `~/.dotfiles/ai/configure-tool-permissions.sh`
4. Run cleanup to remove redundant entries: `~/.dotfiles/ai/bin/cleanup-settings-local.sh`

## Pattern Safety Guidelines

**Safe to auto-approve (read-only):**
- `Bash(kubectl get:*)`, `Bash(kubectl describe:*)`
- `Bash(docker ps:*)`, `Bash(docker images:*)`
- `Bash(aws s3 ls:*)`
- `WebFetch(domain:*)` for documentation sites

**Require review (side effects):**
- `Bash(kubectl delete:*)`, `Bash(kubectl apply:*)`
- `Bash(docker rm:*)`, `Bash(docker exec:*)`
- `Bash(aws s3 rm:*)`
- `Bash(rm:*)`, `Bash(mv:*)`

**Never auto-approve:**
- `Bash(sudo:*)`
- `Bash(chmod 777:*)`
- Patterns that could leak secrets
