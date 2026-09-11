#!/bin/bash
# Install the Telegram "working…" progress indicator: hooks + a standalone
# watchdog (sentry). Plugin-independent — needs no changes to the official
# telegram plugin, so it survives plugin updates.
#
# What you get:
#   - inbound Telegram message  -> a "✍️ Dolgozom rajta…" placeholder appears
#   - the agent sends a reply   -> the placeholder is deleted the instant the
#                                  answer goes out (PostToolUse), Stop as fallback
#   - the turn never finishes    -> a watchdog rewrites the placeholder into a
#     (crash/wedged/agent down)    clear error, so the user always gets either an
#                                  answer or an explicit failure
#
# What it does:
#   0. Provider gate: if CHANNEL_PROVIDER (install .env) resolves to anything
#      but "telegram", it retires any leftover Telegram plumbing and exits 0 --
#      nothing below runs. This is what keeps sync-hooks.sh (which runs every
#      installer on every update) from resurrecting the retired provider.
#   1. Copies the 4 hook scripts to ~/.claude/hooks/
#   2. Patches ~/.claude/settings.json idempotently:
#        UserPromptSubmit -> telegram_progress.py
#        PostToolUse(telegram.*reply) -> telegram_progress_reply_clear.py
#        Stop -> telegram_progress_clear.py
#   3. Retires the Slack progress plumbing (hooks + watchdog) so exactly one
#      provider's indicator is live -- see retire-progress-watchdog.sh.
#   4. Installs the watchdog as a launchd agent (macOS) or systemd
#      service+timer (Linux), running ~every 60s.
#
# Idempotent: safe to re-run (e.g. from sync-hooks.sh on every update).
#
# Usage:
#   bash ~/ClaudeClaw/scripts/install-telegram-progress-hook.sh

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)/hooks"
DEST_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"

# The watchdog unit/label name keys off SERVICE_ID, matching install-linux.sh's
# ${SERVICE_ID}-dashboard/-channels units and the macOS com.${SERVICE_ID}.*
# launchd labels. Derive it from the install .env so a renamed install
# (BOT_NAME != Marveen) does NOT get an orphaned marveen-* unit left behind.
INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Read a single key from a .env file without sourcing it.
# Sourcing executes the file: an unquoted value with spaces (e.g. OWNER_NAME=Foo Bar)
# causes bash to run the trailing word as a command; a $(...) value runs arbitrary code.
# This function uses grep + pure string manipulation -- no eval, no subshell execution.
# MARVEEN_ENV_FILE: test hook only (scripts/__tests__/*progress-hook*.test.sh)
# -- lets a test point the installer at a temp .env instead of the checkout's.
read_env() {
  local f="${MARVEEN_ENV_FILE:-$INSTALL_DIR/.env}"
  [ -f "$f" ] || return 0
  local v
  v="$(grep -E "^${1}=" "$f" | tail -1)" || return 0
  v="${v#*=}"
  case "$v" in
    '"'*) v="${v#\"}"; v="${v%\"}" ;;
    "'"*) v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}
SERVICE_ID="$(read_env SERVICE_ID)"
MAIN_AGENT_ID_ENV="$(read_env MAIN_AGENT_ID)"
BOT_NAME="$(read_env BOT_NAME)"
SERVICE_ID="${SERVICE_ID:-${MAIN_AGENT_ID_ENV:-marveen}}"
BOT_NAME="${BOT_NAME:-Marveen}"

# --- Provider gate (order-independent) --------------------------------------
# sync-hooks.sh runs EVERY install-*-hook.sh on every update, in glob order
# (slack first, telegram last). Each installer used to wire its own hooks and
# timer unconditionally and only the cross-retire below was guarded, so a
# Slack install ended every update with BOTH providers live: the Telegram
# installer re-wired telegram_progress*.py and re-enabled its timer after this
# script had retired them (its retire of slack was refused by the
# active-provider guard). Exactly one provider's progress machinery may be
# live -- the one in CHANNEL_PROVIDER -- so an installer whose provider is
# not the active one retires ITSELF and stops here, before copying, patching
# or writing units. Resolution mirrors src/channel-provider.ts: exact known
# value, anything else (empty, "none", typo) means telegram.
ACTIVE_PROVIDER="$(read_env CHANNEL_PROVIDER | tr -d ' \t\r')"
case "$ACTIVE_PROVIDER" in
  telegram|slack|discord|googlechat|teams) ;;
  *) ACTIVE_PROVIDER="telegram" ;;
esac
if [ "$ACTIVE_PROVIDER" != "telegram" ]; then
  echo "⊙ CHANNEL_PROVIDER=$ACTIVE_PROVIDER -- Telegram progress indicator not installed; retiring any leftover Telegram plumbing"
  bash "$INSTALL_DIR/scripts/retire-progress-watchdog.sh" telegram || true
  exit 0
fi

SUBMIT_HOOK="$DEST_DIR/telegram_progress.py"
STOP_HOOK="$DEST_DIR/telegram_progress_clear.py"
REPLY_HOOK="$DEST_DIR/telegram_progress_reply_clear.py"
WATCHDOG="$DEST_DIR/telegram_progress_watchdog.py"
# Agent-invoked CLI (not a settings.json hook): the Bot API fallback sender that
# clears the placeholder on manual delivery so the Stop hook never re-sends.
FALLBACK_SEND="$DEST_DIR/telegram_fallback_send.py"

for f in telegram_progress.py telegram_progress_clear.py \
         telegram_progress_reply_clear.py telegram_progress_watchdog.py \
         telegram_fallback_send.py; do
  if [ ! -f "$SRC_DIR/$f" ]; then
    echo "❌ Source hook not found: $SRC_DIR/$f" >&2
    exit 1
  fi
done

mkdir -p "$DEST_DIR"
cp "$SRC_DIR/telegram_progress.py"             "$SUBMIT_HOOK"
cp "$SRC_DIR/telegram_progress_clear.py"       "$STOP_HOOK"
cp "$SRC_DIR/telegram_progress_reply_clear.py" "$REPLY_HOOK"
cp "$SRC_DIR/telegram_progress_watchdog.py"    "$WATCHDOG"
cp "$SRC_DIR/telegram_fallback_send.py"        "$FALLBACK_SEND"
chmod +x "$SUBMIT_HOOK" "$STOP_HOOK" "$REPLY_HOOK" "$WATCHDOG" "$FALLBACK_SEND"
echo "✓ Hooks installed in $DEST_DIR"

if [ ! -f "$SETTINGS" ]; then
  echo '{"hooks":{}}' > "$SETTINGS"
fi

# Resolve an absolute python3 for both the hooks and the daemon unit.
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "❌ python3 not found in PATH" >&2
  exit 1
fi

# --- Patch settings.json idempotently --------------------------------------
# PYTHONIOENCODING pins stdout to utf-8 so the checkmark below can't crash the
# installer on a platform whose default console codec (e.g. Windows cp1252)
# can't encode it -- same as the Slack installer.
PYTHONIOENCODING=utf-8 "$PY" - "$SETTINGS" "$PY" "$SUBMIT_HOOK" "$STOP_HOOK" "$REPLY_HOOK" <<'PYEOF'
import json, sys

settings_path, py, submit_hook, stop_hook, reply_hook = sys.argv[1:6]
with open(settings_path) as f:
    cfg = json.load(f)
hooks = cfg.setdefault('hooks', {})

def cmd(path):
    return f"{py} {path}"

def has_command(group_list, command, matcher=None):
    for g in group_list:
        if matcher is not None and g.get('matcher') != matcher:
            continue
        for h in g.get('hooks', []):
            if h.get('command') == command:
                return True
    return False

def find_group(group_list, matcher):
    for g in group_list:
        if g.get('matcher') == matcher:
            return g
    return None

changed = False

# UserPromptSubmit (no matcher) -> placeholder
ups = hooks.setdefault('UserPromptSubmit', [])
if not has_command(ups, cmd(submit_hook)):
    grp = next((g for g in ups if 'matcher' not in g), None)
    if grp is None:
        grp = {'hooks': []}
        ups.append(grp)
    grp.setdefault('hooks', []).append(
        {'type': 'command', 'command': cmd(submit_hook), 'timeout': 15})
    changed = True

# Stop (no matcher) -> clear fallback
stop = hooks.setdefault('Stop', [])
if not has_command(stop, cmd(stop_hook)):
    grp = next((g for g in stop if 'matcher' not in g), None)
    if grp is None:
        grp = {'hooks': []}
        stop.append(grp)
    grp.setdefault('hooks', []).append(
        {'type': 'command', 'command': cmd(stop_hook), 'timeout': 15})
    changed = True

# PostToolUse(matcher="telegram.*reply") -> clear on reply
post = hooks.setdefault('PostToolUse', [])
if not has_command(post, cmd(reply_hook), matcher='telegram.*reply'):
    grp = find_group(post, 'telegram.*reply')
    if grp is None:
        grp = {'matcher': 'telegram.*reply', 'hooks': []}
        post.append(grp)
    grp.setdefault('hooks', []).append(
        {'type': 'command', 'command': cmd(reply_hook), 'timeout': 15})
    changed = True

if changed:
    with open(settings_path, 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print("✓ settings.json hooks patched (UserPromptSubmit / PostToolUse / Stop)")
else:
    print("⊙ settings.json already has the progress hooks — skipping")
PYEOF

# --- Retire the other provider's progress plumbing -------------------------
# Installing Telegram does not automatically unwire Slack: after a migration
# both hook sets stayed in settings.json and BOTH watchdog timers kept firing,
# the dead one scanning state dirs that no longer existed 1440x/day. Exactly
# one provider's progress machinery should be live -- the one in
# CHANNEL_PROVIDER. Never fatal: a failure here must not block the install.
bash "$INSTALL_DIR/scripts/retire-progress-watchdog.sh" slack || true

# --- Install the watchdog daemon -------------------------------------------
OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
  PLIST_DIR="$HOME/Library/LaunchAgents"
  LABEL="com.${SERVICE_ID}.telegram-progress-watchdog"
  PLIST="$PLIST_DIR/$LABEL.plist"
  LOG="$HOME/.claude/channels/telegram-progress-watchdog.log"
  mkdir -p "$PLIST_DIR" "$HOME/.claude/channels"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$WATCHDOG</string>
    </array>
    <!-- launchd's default PATH is minimal; the watchdog shells out to tmux. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLISTEOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST" 2>/dev/null || true
  echo "✓ Watchdog installed (launchd: $LABEL, every 60s)"
else
  # Linux: systemd user service + timer
  UNIT_DIR="$HOME/.config/systemd/user"
  SVC="${SERVICE_ID}-telegram-progress-watchdog"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/$SVC.service" <<UNITEOF
[Unit]
Description=${BOT_NAME} Telegram progress-indicator watchdog (sentry)

[Service]
Type=oneshot
ExecStart=$PY $WATCHDOG
UNITEOF
  cat > "$UNIT_DIR/$SVC.timer" <<TIMEREOF
[Unit]
Description=Run the Telegram progress watchdog every 60s
Requires=$SVC.service

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=10s

[Install]
WantedBy=timers.target
TIMEREOF
  if pidof systemd >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    systemctl --user daemon-reload
    systemctl --user enable --now "$SVC.timer" 2>/dev/null || true
    echo "✓ Watchdog installed (systemd timer: $SVC.timer, every 60s)"
  else
    echo "⚠ systemd --user not available — units written to $UNIT_DIR"
    echo "  Enable later: systemctl --user enable --now $SVC.timer"
  fi
fi

echo ""
echo "Done. Telegram turns now show a 'Dolgozom rajta…' placeholder that clears"
echo "on reply, and a watchdog turns any stuck turn into a clear error."
