# Disk Space Monitoring & Maintenance Guide

## Automated Monitoring

Your system now has automated disk space monitoring that:

- **Checks disk usage every hour**
- **Warns at 85% full** with a "Purr" notification sound
- **Critical alert at 90% full** with a "Basso" notification sound
- **Logs all activity** to `~/.dotfiles/.notes/disk-monitor.log`

### Service Management

```bash
# Check if monitoring service is running
launchctl list | grep disk-monitor

# Stop monitoring service
launchctl unload ~/Library/LaunchAgents/com.haacked.disk-monitor.plist

# Start monitoring service
launchctl load ~/Library/LaunchAgents/com.haacked.disk-monitor.plist

# View monitoring logs
disk-monitor-log
```

## Quick Cleanup Commands

### Available Aliases

- `disk-check` - Manual disk space check with notifications
- `disk-usage` - Show current disk usage (same as `df -h`)
- `disk-cleanup` - Comprehensive cleanup (all commands below)
- `disk-cleanup-docker` - Clean Docker/OrbStack only
- `disk-cleanup-caches` - Clean application caches only
- `disk-monitor-log` - View monitoring log in real-time

### Manual Cleanup Commands

#### Homebrew (Usually saves 2-5GB)
```bash
brew cleanup --prune=all
```

#### Node.js Package Managers (Usually saves 2-8GB)
```bash
yarn cache clean
pnpm store prune
```

#### Python Packages (Usually saves 2-6GB)
```bash
uv cache clean                    # If uv is installed
rm -rf ~/.cache/uv               # Manual cleanup
```

#### Docker/OrbStack (Usually saves 5-15GB)
```bash
docker system prune -a -f --volumes    # Remove all unused resources
docker container prune -f              # Remove stopped containers only
docker image prune -a -f               # Remove unused images only
docker volume prune -f                 # Remove unused volumes only
```

#### Application Caches (Usually saves 3-10GB)
```bash
rm -rf ~/.cache/puppeteer              # Browser automation cache
rm -rf ~/Library/Caches/JetBrains      # IDE caches
rm -rf ~/Library/Caches/Google         # Google Chrome caches
rm -rf ~/Library/Caches/Homebrew       # Homebrew download cache
```

#### iOS Simulators (Usually saves 10-50GB)
```bash
xcrun simctl delete unavailable        # Remove old/broken simulators
xcrun simctl list devices               # List all simulators
```

## Monitoring Thresholds

- **Warning**: 85% full (yellow notification)
- **Critical**: 90% full (red notification with sound)

### Customizing Thresholds

Edit `/Users/haacked/.dotfiles/bin/check-disk-space`:

```bash
WARNING_THRESHOLD=85   # Change to desired warning percentage
CRITICAL_THRESHOLD=90  # Change to desired critical percentage
```

After editing, reload the service:
```bash
launchctl unload ~/Library/LaunchAgents/com.haacked.disk-monitor.plist
launchctl load ~/Library/LaunchAgents/com.haacked.disk-monitor.plist
```

## Emergency Cleanup

If disk is critically full and system is slow:

1. **Docker cleanup** (fastest, biggest impact):
   ```bash
   docker system prune -a -f --volumes
   ```

2. **Cache cleanup**:
   ```bash
   rm -rf ~/.cache/uv ~/.cache/puppeteer ~/Library/Caches/JetBrains
   ```

3. **Homebrew cleanup**:
   ```bash
   brew cleanup --prune=all
   ```

4. **Package manager cleanup**:
   ```bash
   yarn cache clean && pnmp store prune
   ```

## Log Files

- **Monitoring log**: `~/.dotfiles/.notes/disk-monitor.log`
- **Error log**: `~/.dotfiles/.notes/disk-monitor-error.log` 
- **Service output**: `~/.dotfiles/.notes/disk-monitor-output.log`

## Typical Space Usage

After cleanup, expect:
- **Docker**: 3-5GB (active containers/images)
- **Node modules**: 2-3GB (active projects)
- **Homebrew**: 1-2GB (essential packages)
- **Python packages**: 1-2GB (active environments)
- **Application caches**: <1GB (will rebuild as needed)

## One-Time Setup Complete

✅ Automated monitoring service installed
✅ Notification alerts configured  
✅ Cleanup aliases added to shell
✅ Documentation created

The system will now automatically monitor your disk space and alert you before it becomes critically full!