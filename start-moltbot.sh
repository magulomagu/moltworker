#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# This script:
# 1. Restores config from R2 backup if available
# 2. Configures moltbot from environment variables
# 3. Starts a background sync to backup config to R2
# 4. Starts the gateway

set -e

# Check if clawdbot gateway is already running - bail early if so
# Note: CLI is still named "clawdbot" until upstream renames it
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# Paths (clawdbot paths are used internally - upstream hasn't renamed yet)
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

# Create config directory
mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================
# Check if R2 backup exists by looking for clawdbot.json
# The BACKUP_DIR may exist but be empty if R2 was just mounted
# Note: backup structure is $BACKUP_DIR/clawdbot/ and $BACKUP_DIR/skills/

# Helper function to check if R2 backup is newer than local
should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"
    
    # If no R2 sync timestamp, don't restore
    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi
    
    # If no local sync timestamp, restore from R2
    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi
    
    # Compare timestamps
    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)
    
    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"
    
    # Convert to epoch seconds for comparison
    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")
    
    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

if [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    if should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/clawdbot..."
        cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
        # Copy the sync timestamp to local so we know what version we have
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Legacy backup format (flat structure)
    if should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR..."
        cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from legacy R2 backup"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore skills from R2 backup if available (only if R2 is newer)
SKILLS_DIR="/root/clawd/skills"
if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring skills from $BACKUP_DIR/skills..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    fi
fi

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Create minimal config if template doesn't exist
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << EOFNODE
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Clean up any broken anthropic provider config from previous runs
// (older versions didn't include required 'name' field)
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}



// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided (but not in dev mode)
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    // Production mode: use token if provided
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    const telegramDmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram.dmPolicy = telegramDmPolicy;
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        // Explicit allowlist: "123,456,789" → ['123', '456', '789']
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (telegramDmPolicy === 'open') {
        // "open" policy requires allowFrom: ["*"]
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Note: Discord uses nested dm.policy, not flat dmPolicy like Telegram
// See: https://github.com/moltbot/moltbot/blob/v2026.1.24-1/src/config/zod-schema.providers-core.ts#L147-L155
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    const discordDmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = discordDmPolicy;
    // "open" policy requires allowFrom: ["*"]
    if (discordDmPolicy === 'open') {
        config.channels.discord.dm.allowFrom = ['*'];
    }
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// Determine default model based on available API keys
// Primary: Claude Haiku 4.5, Secondary: Gemini 3 Flash
const defaultModel = (() => {
    if (process.env.CF_AI_GATEWAY_MODEL) return process.env.CF_AI_GATEWAY_MODEL;
    if (process.env.ANTHROPIC_API_KEY) return 'anthropic/claude-haiku-4-5-20251001';
    if (process.env.GOOGLE_AI_STUDIO_API_KEY) return 'google/gemini-3-flash-preview';
    const gwUrl = process.env.AI_GATEWAY_BASE_URL || '';
    if (gwUrl.includes('google-ai-studio')) return 'google/gemini-3-flash-preview';
    return 'google/gemini-3-flash-preview';
})();
const primaryModel = defaultModel;
const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');

console.log('Primary Model Override:', process.env.CF_AI_GATEWAY_MODEL || '(not set, using default)');
console.log('Base URL Override:', baseUrl || '(not set)');

config.models = config.models || {};
config.models.providers = config.models.providers || {};

// Configure Anthropic
if (process.env.ANTHROPIC_API_KEY || (baseUrl && !baseUrl.includes('google-ai-studio') && !baseUrl.includes('openai'))) {
    console.log('Configuring Anthropic provider');
    config.models.providers.anthropic = {
        baseUrl: (baseUrl && !baseUrl.includes('google-ai-studio') && !baseUrl.includes('openai')) ? baseUrl : 'https://api.anthropic.com',
        api: 'anthropic-messages',
        models: [
            { id: 'claude-opus-4-6', name: 'Claude Opus 4.6', contextWindow: 200000 },
            { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
            { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
        ]
    };
    if (process.env.ANTHROPIC_API_KEY) {
        config.models.providers.anthropic.apiKey = process.env.ANTHROPIC_API_KEY;
    }
}

// Configure Gemini (Google AI Studio)
if (process.env.GOOGLE_AI_STUDIO_API_KEY || baseUrl.includes('google-ai-studio')) {
    console.log('Configuring Google AI Studio (Gemini) provider');
    config.models.providers['google-ai-studio'] = {
        baseUrl: baseUrl.includes('google-ai-studio') ? baseUrl : 'https://generativelanguage.googleapis.com',
        api: 'google-generative-ai',
        models: [
            { id: 'gemini-3-flash-preview', name: 'Gemini 3 Flash Preview', contextWindow: 1048576 },
            { id: 'gemini-3-pro-preview', name: 'Gemini 3 Pro Preview', contextWindow: 1048576 },
            { id: 'gemini-2.5-flash', name: 'Gemini 2.5 Flash', contextWindow: 1048576 },
            { id: 'gemini-2.5-pro', name: 'Gemini 2.5 Pro', contextWindow: 2097152 },
            { id: 'gemini-1.5-pro', name: 'Gemini 1.5 Pro', contextWindow: 2097152 },
            { id: 'gemini-1.5-flash', name: 'Gemini 1.5 Flash', contextWindow: 1048576 },
        ]
    };
    if (process.env.GOOGLE_AI_STUDIO_API_KEY) {
        config.models.providers['google-ai-studio'].apiKey = process.env.GOOGLE_AI_STUDIO_API_KEY;
    }
}

// Configure OpenAI
if (process.env.OPENAI_API_KEY || (baseUrl && baseUrl.includes('openai'))) {
    console.log('Configuring OpenAI provider');
    config.models.providers.openai = {
        baseUrl: baseUrl.includes('openai') ? baseUrl : 'https://api.openai.com',
        api: 'openai-responses',
        models: [
            { id: 'o3', name: 'o3', contextWindow: 200000 },
            { id: 'o4-mini', name: 'o4-mini', contextWindow: 200000 },
            { id: 'gpt-4.1', name: 'GPT-4.1', contextWindow: 1048576 },
            { id: 'gpt-4.1-mini', name: 'GPT-4.1 Mini', contextWindow: 1048576 },
            { id: 'gpt-4.1-nano', name: 'GPT-4.1 Nano', contextWindow: 1048576 },
            { id: 'gpt-4o', name: 'GPT-4o', contextWindow: 128000 },
            { id: 'gpt-4o-mini', name: 'GPT-4o Mini', contextWindow: 128000 },
        ]
    };
    if (process.env.OPENAI_API_KEY) {
        config.models.providers.openai.apiKey = process.env.OPENAI_API_KEY;
    }
}

// Set Primary Model (ensure it has the provider prefix)
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
const modelPrefix = process.env.GOOGLE_AI_STUDIO_API_KEY ? 'google-ai-studio' : 'anthropic';
config.agents.defaults.model.primary = primaryModel.includes('/') ? primaryModel.replace('google/', 'google-ai-studio/') : modelPrefix + '/' + primaryModel;

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
# Note: R2 backup sync is handled by the Worker's cron trigger
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
