# Mission Control - Claude Code Status Line

**Ground Control to Major Tom... your context fuel is color-coded!**

## Mission Status HUD

Every Claude Code session is a space mission. This plugin gives you NASA-grade situational awareness with color-coded telemetry.

## Requirements

**System dependencies**:
- **Python 3.6+** (uses f-strings, pathlib)
- Standard library only (json, sys, os)

**Verification**:
```bash
# Check Python version
python3 --version

# Should show: Python 3.6.0 or higher
```

**Most systems have Python 3 pre-installed**:
- macOS: Python 3 included by default (10.15+)
- Linux: Standard on all modern distributions
- Windows: Install from python.org or Microsoft Store

## Installation

```bash
# Install plugin
/plugin install acf-mission-control@acf-tools

# Restart Claude Code to load plugin
# Status line auto-configures on first session
```

**What happens on first run:**
1. Creates `.claude/scripts/` directory in your repo
2. Copies `status-line.py` from plugin to `.claude/scripts/`
3. Makes script executable (`chmod +x`)
4. Configures statusLine in `.claude/settings.json` to use local copy
5. Status line appears immediately (no manual setup required)

**Key benefit:** Script becomes part of your repo - works even after plugin uninstall, can be customized per-project.

**Verification:**
```bash
# Check script was copied (from project root)
ls -la .claude/scripts/status-line.py

# Check settings were updated
cat .claude/settings.json | grep -A 4 statusLine

# Should show:
# "statusLine": {
#   "type": "command",
#   "command": ".claude/scripts/status-line.py",
#   "padding": 0
# }
```

## Telemetry Display

Format: `Model | 📁 directory | ⚡️ branch | [████] percentage (tokens)`

Example:
```
Sonnet 4.5 | 📁 acf-tools | ⚡️ main | [████████░░] 45.2% (90,400)
```

**No brackets around model name** - Clean, readable display.

## Fuel Gauge Color Zones

Context is your rocket fuel. Monitor the color-coded bar:

| Zone | Context % | Bar Color | Status |
|------|-----------|-----------|--------|
| **Green** | 0-50% | 🟩 Green | All systems nominal |
| **Yellow** | 50-70% | 🟨 Yellow | Caution - plan next moves |
| **Red** | 70%+ | 🟥 Red | Critical - compact imminent |

**At 78%** - Houston, we have a problem! Claude Code auto-triggers `/compact`

## Visual Examples

### Green Zone (30% context)
```
Sonnet 4.5 | 📁 my-project | ⚡️ feature-auth | [████░░░░░░░░░░░░░░░░] 30.0% (60,000)
                                                  ↑ Green filled bars
```

### Yellow Zone (65% context)
```
Sonnet 4.5 | 📁 my-project | ⚡️ feature-auth | [█████████████░░░░░░░] 65.0% (130,000)
                                                  ↑ Yellow filled bars
```

### Red Zone (82% context - CRITICAL)
```
Sonnet 4.5 | 📁 my-project | ⚡️ feature-auth | [████████████████░░░░] 82.0% (164,000)
                                                  ↑ Red filled bars - AUTO-COMPACT!
```

## Deployment

### Pre-Installation Check

```bash
# Verify Python 3 available
python3 --version

# If not found, install Python 3
# macOS: brew install python3
# Ubuntu/Debian: sudo apt install python3
# Fedora/RHEL: sudo dnf install python3
# Windows: Download from python.org
```

### Plugin Installation

```bash
# Install from marketplace
/plugin install acf-mission-control@acf-tools

# Verify installation
/plugin list
# Should show: acf-mission-control (enabled)

# Restart Claude Code
# Auto-setup runs on first SessionStart
```

### Auto-Configuration Process

**What the plugin does automatically:**

1. **On first SessionStart:** Setup hook runs
2. **Creates directories:** Makes `.claude/` and `.claude/scripts/` if needed
3. **Copies script:** Copies `status-line.py` from plugin to `.claude/scripts/` (if not present)
4. **Makes executable:** Sets execute permissions on local script
5. **Checks settings:** Reads `.claude/settings.json` (creates if missing)
6. **Adds configuration:** Injects statusLine pointing to `.claude/scripts/status-line.py`
7. **You see:** `🚀 Mission Control activated` message

**Script location:** `.claude/scripts/status-line.py` (local copy, part of your repo)

**After auto-setup completes:**
```
Sonnet 4.5 | 📁 current-dir | ⚡️ branch | [████] X.X% (tokens)
```

### Manual Setup (if auto-setup fails)

If auto-configuration doesn't work, manually set up:

```bash
# 1. Create directories
mkdir -p .claude/scripts

# 2. Copy script from plugin (adjust path if needed)
cp ~/.claude/plugins/acf-mission-control/hooks/handlers/status-line.py .claude/scripts/

# 3. Make executable
chmod +x .claude/scripts/status-line.py

# 4. Configure settings
cat > .claude/settings.json << 'EOF'
{
  "statusLine": {
    "type": "command",
    "command": ".claude/scripts/status-line.py",
    "padding": 0
  }
}
EOF
```

Then restart Claude Code.

## Technical Details

### Auto-Setup Hook
- **Event:** SessionStart (runs on startup, resume, clear, compact)
- **Actions:**
  1. Creates `.claude/scripts/` directory
  2. Copies `status-line.py` from plugin to `.claude/scripts/`
  3. Makes script executable
  4. Configures statusLine in `.claude/settings.json` to use local copy
- **Scope:** Project-level (script becomes part of repo)
- **Idempotent:** Skips if script exists and statusLine configured
- **Non-blocking:** Fails gracefully if copy/setup fails

### Script Architecture
- **Plugin copy:** `~/.claude/plugins/acf-mission-control/hooks/handlers/status-line.py`
- **Local copy:** `.claude/scripts/status-line.py` (what statusLine uses)
- **Benefit:** Works after plugin uninstall, can be customized per-project
- **Committable:** Script is part of repo, can be version controlled

### Context Limit Calculation
- Base: 200,000 tokens
- Trigger threshold: 78% (156,000 tokens)
- Claude Code auto-compacts at 78% to prevent context overflow

### Color Implementation
Uses ANSI escape codes for terminal color:
- Green: `\033[92m`
- Yellow: `\033[93m`
- Red: `\033[91m`

### Git Branch Detection
Reads `.git/HEAD` to extract current branch. Shows nothing if not in git repo.

### Data Source
Parses transcript JSON from latest assistant message to extract token usage:
- `input_tokens`
- `cache_creation_input_tokens`
- `cache_read_input_tokens`
- `output_tokens`

## Troubleshooting

### Status line not appearing

**Symptom**: No status line after plugin installation

**Primary Debugging Steps**:
```bash
# 1. Enable debug mode
claude --debug
# Look for: "Loading plugin: acf-mission-control" and any errors

# 2. Verify plugin installation
/plugin list
# Should show: acf-mission-control@acf-tools (enabled)

# 3. If not in list, reinstall
/plugin marketplace add ./acf-tools
/plugin install acf-mission-control@acf-tools
```

**Secondary Checks** (if plugin loads but status line doesn't work):
```bash
# 4. Check Python available
python3 --version

# 5. Verify script was copied
ls -la .claude/scripts/status-line.py

# 6. Verify auto-setup ran
cat .claude/settings.json | grep statusLine

# 7. Manual test of status line script
cd .claude/scripts/
echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"/tmp"},"transcript_path":"/dev/null"}' | python3 status-line.py

# Should output: Test | 📁 tmp | [░░░░░░░░░░░░░░░░░░░░] 0.0% (0)
```

**Solutions**:
1. **Plugin not enabled:** `/plugin enable acf-mission-control`
2. **Script not copied:** Run manual setup (see Manual Setup section)
3. **Settings file missing:** Create `.claude/settings.json` (auto-setup should do this)
4. **Restart required:** Restart Claude Code after plugin installation

### Auto-setup failed

**Symptom**: Setup hook reports error or statusLine not in settings

**Diagnosis**:
```bash
# Check if directories exist
ls -la .claude/
ls -la .claude/scripts/

# Check if script was copied
ls -la .claude/scripts/status-line.py

# Check if settings file exists
ls -la .claude/settings.json
```

**Solutions**:
1. **Script not executable:** `chmod +x .claude/scripts/status-line.py`
2. **Missing directories:** `mkdir -p .claude/scripts`
3. **Complete failure:** Use Manual Setup process (see above)

### Python not found error

**Symptom**: Error about python3 command not found

**Diagnosis**:
```bash
# Check if Python installed
which python3
python3 --version
```

**Solution**:
```bash
# macOS
brew install python3

# Ubuntu/Debian
sudo apt update
sudo apt install python3

# Fedora/RHEL
sudo dnf install python3

# Windows
# Download and install from python.org or Microsoft Store
```

### Colors not showing

**Symptom**: Bar shows color codes instead of colors

**Cause**: Terminal doesn't support ANSI escape codes

**Solution**: Use modern terminal:
- macOS: Terminal.app, iTerm2
- Linux: gnome-terminal, konsole, kitty
- Windows: Windows Terminal, ConEmu

### Git branch not showing

**Symptom**: Git branch missing from status line

**Diagnosis**:
```bash
# Verify in git repository
git status

# Check .git/HEAD exists
cat .git/HEAD
```

**Solution**: Navigate to git repository root. Branch shows only in git repos.

### Percentage stuck at 0%

**Symptom**: Context usage shows 0.0% (0)

**Cause**: No transcript data yet (first message in session)

**Solution**: Normal behavior. Updates after first assistant response.

### Permission denied error

**Symptom**: Permission denied when executing status-line.py

**Diagnosis**:
```bash
# Check script executable (local copy)
ls -la .claude/scripts/status-line.py
```

**Solution**:
```bash
# Make script executable
chmod +x .claude/scripts/status-line.py
```

## Customization

**Script location:** `.claude/scripts/status-line.py` (local copy in your repo)

**Per-project customization:**
```bash
# Edit local copy
vim .claude/scripts/status-line.py

# Changes apply to this project only
# Other projects use their own copies
```

**Examples:**
- Adjust color thresholds (50/70 → 40/80)
- Change bar length (20 chars → 30 chars)
- Modify format/emojis
- Add custom metrics

**No plugin reinstall needed** - changes take effect on next status line update.

## Uninstallation

```bash
# Disable and uninstall plugin
/plugin disable acf-mission-control
/plugin uninstall acf-mission-control

# Status line KEEPS WORKING (uses local copy)
# To remove status line:
rm .claude/scripts/status-line.py
# Edit .claude/settings.json and delete statusLine block
```

**Note:** Uninstalling the plugin doesn't break status line. Local script in `.claude/scripts/` continues working independently.

## Ground Control Wisdom

> "Houston, context management is not a suggestion. It's mission-critical."

Monitor your fuel gauge. Plan your context usage. Never run out mid-mission.

## System Requirements Summary

| Requirement | Version | Status |
|-------------|---------|--------|
| Python | 3.6+ | Required |
| Standard library | json, sys, os | Included |
| ANSI terminal | Color support | Recommended |
| Git | Any version | Optional (for branch display) |

## Performance Impact

**Negligible overhead**:
- Executes once per status line update
- Reads single transcript file
- Parses JSON (< 10ms)
- No network calls
- No external dependencies

## Contributing

See [Contributing Guide](../../CONTRIBUTING.md) for improvements.

## Support

- Issues: [GitHub Issues](https://github.com/fib7/acf-tools/issues)
- Discussions: [GitHub Discussions](https://github.com/fib7/acf-tools/discussions)

---

**Mission Control out.** 🚀
