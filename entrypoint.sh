#!/bin/sh
# Entrypoint: ensure dangerouslyDisableDeviceAuth is set before gateway starts.

export HOME=/home/node
CONFIG_FILE="$HOME/.openclaw/openclaw.json"
mkdir -p "$(dirname "$CONFIG_FILE")"
mkdir -p "$HOME/.openclaw/workspace"

# Seed configuration from repository if present
if [ -d "/app/config" ]; then
  echo "[entrypoint] Seeding configuration from /app/config..."
  if [ -f "/app/config/openclaw.json" ]; then
    cp "/app/config/openclaw.json" "$CONFIG_FILE"
  fi
  if [ -f "/app/config/SOUL.md" ]; then
    cp "/app/config/SOUL.md" "$HOME/.openclaw/workspace/SOUL.md"
  fi
  if [ -f "/app/config/IDENTITY.md" ]; then
    cp "/app/config/IDENTITY.md" "$HOME/.openclaw/workspace/IDENTITY.md"
  fi
  if [ -f "/app/config/HEARTBEAT.md" ]; then
    cp "/app/config/HEARTBEAT.md" "$HOME/.openclaw/workspace/HEARTBEAT.md"
  fi
  if [ -f "/app/config/MEMORY.md" ]; then
    cp "/app/config/MEMORY.md" "$HOME/.openclaw/workspace/MEMORY.md"
  fi
  if [ -f "/app/config/USER.md" ]; then
    cp "/app/config/USER.md" "$HOME/.openclaw/workspace/USER.md"
  elif [ ! -f "$HOME/.openclaw/workspace/USER.md" ]; then
    cat > "$HOME/.openclaw/workspace/USER.md" << 'USEREOF'
# USER.md

This file stores context about the user that OpenClaw should remember across sessions.

## Owner
- **Name**: Dale
- **Telegram ID**: 7349890794

<!-- OpenClaw will update this file as it learns more about you -->
USEREOF
    echo "[entrypoint] Created default USER.md in workspace"
  fi
  if [ -d "/app/config/agents" ]; then
    echo "[entrypoint] Seeding agents from /app/config/agents..."
    mkdir -p "$HOME/.openclaw/agents"
    cp -R /app/config/agents/* "$HOME/.openclaw/agents/"
  fi
fi

# Ensure mandatory workspace files exist (to avoid ENOENT errors)
for f in SOUL.md IDENTITY.md HEARTBEAT.md MEMORY.md; do
  if [ ! -f "$HOME/.openclaw/workspace/$f" ]; then
    echo "# $f" > "$HOME/.openclaw/workspace/$f"
    echo "[entrypoint] Initialized empty $f in workspace"
  fi
done

# Run logic in Node to handle JSON safely
node - <<'EOF'
const fs = require("fs");
const path = require("path");
const configFile = path.join(process.env.HOME, ".openclaw", "openclaw.json");

let config = {};
if (fs.existsSync(configFile)) {
  try {
    const raw = fs.readFileSync(configFile, "utf8");
    if (raw.trim()) {
      config = JSON.parse(raw);
    }
  } catch (e) {
    console.error("[entrypoint] could not parse existing config:", e.message);
  }
}

// Ensure the controlUi section has required security overrides for Railway
config.gateway = config.gateway || {};
config.gateway.controlUi = config.gateway.controlUi || {};
let updated = false;

if (config.gateway.controlUi.dangerouslyDisableDeviceAuth !== true) {
  config.gateway.controlUi.dangerouslyDisableDeviceAuth = true;
  console.log("[entrypoint] set gateway.controlUi.dangerouslyDisableDeviceAuth = true");
  updated = true;
}

// Set allowedOrigins from RAILWAY_PUBLIC_DOMAIN if available, so the gateway
// validates WebSocket origins properly instead of using the Host-header fallback.
// Falls back to the Host-header fallback only when the domain isn't known.
// Include common Railway domain variations to avoid the Host-header fallback warning.
const railwayPublicDomain = process.env.RAILWAY_PUBLIC_DOMAIN;
if (railwayPublicDomain) {
  const candidateOrigins = [
    "https://" + railwayPublicDomain,
    "https://" + railwayPublicDomain.toLowerCase(),
  ];
  const railwayStaticUrl = process.env.RAILWAY_STATIC_URL;
  if (railwayStaticUrl) {
    candidateOrigins.push(railwayStaticUrl.startsWith("https://") ? railwayStaticUrl : "https://" + railwayStaticUrl);
  }
  const existing = config.gateway.controlUi.allowedOrigins || [];
  let originsAdded = false;
  for (const origin of candidateOrigins) {
    if (!existing.includes(origin)) {
      existing.push(origin);
      originsAdded = true;
    }
  }
  if (originsAdded) {
    config.gateway.controlUi.allowedOrigins = existing;
    console.log("[entrypoint] set gateway.controlUi.allowedOrigins:", existing.join(", "));
    updated = true;
  }
}
// Always keep the Host-header fallback enabled on Railway so connections are never
// blocked if allowedOrigins doesn't match (e.g. custom domains, IP access).
if (config.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback !== true) {
  config.gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true;
  console.log("[entrypoint] set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true");
  updated = true;
}

// Bind to 0.0.0.0 when running behind a reverse proxy (Railway, Hetzner+nginx, etc).
// The gateway refuses to bind beyond loopback without an auth token, so inject one.
// Railway also injects PORT (usually 8080) and expects the app to listen there.
const gatewayToken = process.env.OPENCLAW_GATEWAY_TOKEN;
const railwayPort = process.env.PORT ? parseInt(process.env.PORT, 10) : null;
const isRailway = process.env.RAILWAY_ENVIRONMENT || process.env.RAILWAY_SERVICE_NAME || process.env.RAILWAY_ENVIRONMENT_ID || process.env.RAILWAY_SERVICE_ID;
// OPENCLAW_BIND_LAN=1 forces LAN bind on non-Railway hosts (e.g. Hetzner VPS behind nginx).
const forceBindLan = process.env.OPENCLAW_BIND_LAN === "1" || isRailway;
if (forceBindLan) {
  if (config.gateway.bind !== "lan") {
    config.gateway.bind = "lan";
    console.log("[entrypoint] set gateway.bind = lan (0.0.0.0)");
    updated = true;
  }
  if (railwayPort && config.gateway.port !== railwayPort) {
    config.gateway.port = railwayPort;
    console.log(`[entrypoint] Railway detected: set gateway.port = ${railwayPort} (from PORT env var)`);
    updated = true;
  }
  // suppressSecurityWarnings is not a valid config key; skip it.
  const trustedProxies = config.gateway.trustedProxies || [];
  const internalRanges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "172.31.0.0/16"];
  let proxiesAdded = false;
  for (const range of internalRanges) {
    if (!trustedProxies.includes(range)) {
      trustedProxies.push(range);
      proxiesAdded = true;
    }
  }
  // Support OPENCLAW_TRUSTED_PROXIES env var (comma-separated list)
  const extraProxies = process.env.OPENCLAW_TRUSTED_PROXIES;
  if (extraProxies) {
    const list = extraProxies.split(",").map(s => s.trim()).filter(Boolean);
    for (const p of list) {
      if (!trustedProxies.includes(p)) {
        trustedProxies.push(p);
        proxiesAdded = true;
      }
    }
  }
  if (proxiesAdded) {
    config.gateway.trustedProxies = trustedProxies;
    console.log("[entrypoint] added internal ranges to gateway.trustedProxies");
    updated = true;
  }
  config.gateway.auth = config.gateway.auth || {};
  if (gatewayToken) {
    if (config.gateway.auth.token !== gatewayToken) {
      config.gateway.auth.token = gatewayToken;
      console.log("[entrypoint] set gateway.auth.token from OPENCLAW_GATEWAY_TOKEN");
      updated = true;
    }
  } else if (!config.gateway.auth.token) {
    // No env var and no persisted token — auto-generate one and persist it.
    const crypto = require("crypto");
    const generated = crypto.randomBytes(32).toString("hex");
    config.gateway.auth.token = generated;
    console.log("[entrypoint] OPENCLAW_GATEWAY_TOKEN not set — generated gateway token: " + generated);
    console.log("[entrypoint] Copy the token above into your Control UI settings.");
    updated = true;
  } else {
    console.log("[entrypoint] OPENCLAW_GATEWAY_TOKEN not set — using persisted gateway token from config.");
  }

  // Log the tokenized dashboard URL so users can bookmark it and skip the token prompt.
  // The token is embedded as ?token=... — the Control UI reads it on load and auto-connects.
  const dashboardToken = config.gateway.auth.token;
  if (dashboardToken && railwayPublicDomain) {
    const tokenizedUrl = "https://" + railwayPublicDomain + "/?token=" + dashboardToken;
    console.log("[entrypoint] ────────────────────────────────────────────────────");
    console.log("[entrypoint] Bookmark this URL to skip the token prompt on every visit:");
    console.log("[entrypoint] " + tokenizedUrl);
    console.log("[entrypoint] ────────────────────────────────────────────────────");
  }
}

// Inject OPENROUTER_API_KEY into config.env (the canonical location per docs).
// Do NOT write to models.providers.openrouter — that sub-object requires baseUrl+models
// and will fail schema validation if those required fields are absent.
// Also clean up any stale invalid keys previously written to the config.
const openrouterKey = process.env.OPENROUTER_API_KEY;
if (config.models && config.models.providers && config.models.providers.openrouter) {
  delete config.models.providers.openrouter;
  if (Object.keys(config.models.providers).length === 0) delete config.models.providers;
  if (config.models && Object.keys(config.models).length === 0) delete config.models;
  console.log("[entrypoint] removed stale models.providers.openrouter from config");
  updated = true;
}
if (config.gateway && config.gateway.suppressSecurityWarnings !== undefined) {
  delete config.gateway.suppressSecurityWarnings;
  console.log("[entrypoint] removed stale gateway.suppressSecurityWarnings from config");
  updated = true;
}
if (openrouterKey) {
  config.env = config.env || {};
  if (config.env.OPENROUTER_API_KEY !== openrouterKey) {
    config.env.OPENROUTER_API_KEY = openrouterKey;
    console.log("[entrypoint] injected OPENROUTER_API_KEY into config.env.OPENROUTER_API_KEY");
    updated = true;
  }
  // Update models.json for all agents
  const agentsDir = path.join(process.env.HOME, ".openclaw", "agents");
  try {
    const agentDirs = fs.readdirSync(agentsDir);
    for (const agentId of agentDirs) {
      const modelsFile = path.join(agentsDir, agentId, "agent", "models.json");
      const authFile = path.join(agentsDir, agentId, "agent", "auth.json");
      const authProfilesFile = path.join(agentsDir, agentId, "agent", "auth-profiles.json");

      if (fs.existsSync(modelsFile)) {
        try {
          const models = JSON.parse(fs.readFileSync(modelsFile, "utf8"));
          if (models.providers && models.providers.openrouter) {
            models.providers.openrouter.apiKey = openrouterKey;
            fs.writeFileSync(modelsFile, JSON.stringify(models, null, 2));
            console.log(`[entrypoint] injected OPENROUTER_API_KEY into ${agentId}/agent/models.json`);
          }
        } catch (e) { console.warn(`[entrypoint] could not update models.json for ${agentId}:`, e.message); }
      }

      if (fs.existsSync(authFile)) {
        try {
          const auth = JSON.parse(fs.readFileSync(authFile, "utf8"));
          if (auth.openrouter) {
            auth.openrouter.key = openrouterKey;
            fs.writeFileSync(authFile, JSON.stringify(auth, null, 2));
            console.log(`[entrypoint] injected OPENROUTER_API_KEY into ${agentId}/agent/auth.json`);
          }
        } catch (e) { console.warn(`[entrypoint] could not update auth.json for ${agentId}:`, e.message); }
      }

      if (fs.existsSync(authProfilesFile)) {
        try {
          const profiles = JSON.parse(fs.readFileSync(authProfilesFile, "utf8"));
          if (profiles.profiles && profiles.profiles["openrouter:default"]) {
            profiles.profiles["openrouter:default"].key = openrouterKey;
            fs.writeFileSync(authProfilesFile, JSON.stringify(profiles, null, 2));
            console.log(`[entrypoint] injected OPENROUTER_API_KEY into ${agentId}/agent/auth-profiles.json`);
          }
        } catch (e) { console.warn(`[entrypoint] could not update auth-profiles.json for ${agentId}:`, e.message); }
      }
    }
  } catch (e) { console.warn("[entrypoint] could not enumerate agents dir for key injection:", e.message); }
} else {
  console.warn("[entrypoint] WARNING: OPENROUTER_API_KEY is not set. Agent calls to OpenRouter will use the seeded (potentially stale) key.");
}

// Inject TELEGRAM_BOT_TOKEN into channels config
const telegramBotToken = process.env.TELEGRAM_BOT_TOKEN;
if (telegramBotToken) {
  config.channels = config.channels || {};
  config.channels.telegram = config.channels.telegram || {};
  if (config.channels.telegram.botToken !== telegramBotToken) {
    config.channels.telegram.botToken = telegramBotToken;
    console.log("[entrypoint] injected TELEGRAM_BOT_TOKEN into channels.telegram.botToken");
    updated = true;
  }
} else {
  console.warn("[entrypoint] WARNING: TELEGRAM_BOT_TOKEN is not set. Telegram channel may not work.");
}

// Set Claude Haiku via OpenRouter as the default conversation model.
// Uses ANTHROPIC_API_KEY (direct) if available, otherwise falls back to OpenRouter.
// Heartbeat stays on the free OpenRouter model to avoid paid credit usage.
const anthropicKey = process.env.ANTHROPIC_API_KEY;
if (anthropicKey) {
  config.env = config.env || {};
  if (config.env.ANTHROPIC_API_KEY !== anthropicKey) {
    config.env.ANTHROPIC_API_KEY = anthropicKey;
    console.log("[entrypoint] injected ANTHROPIC_API_KEY into config.env.ANTHROPIC_API_KEY");
    updated = true;
  }
  const CLAUDE_MODEL = "claude-haiku-4-5-20251001";
  config.agents = config.agents || {};
  config.agents.defaults = config.agents.defaults || {};
  if (config.agents.defaults.model !== CLAUDE_MODEL) {
    config.agents.defaults.model = CLAUDE_MODEL;
    console.log("[entrypoint] set agents.defaults.model to Claude (direct):", CLAUDE_MODEL);
    updated = true;
  }
} else if (process.env.OPENROUTER_API_KEY) {
  // No direct Anthropic key — use Claude Haiku via OpenRouter instead.
  const CLAUDE_VIA_OPENROUTER = "openrouter/anthropic/claude-haiku-4-5-20251001";
  config.agents = config.agents || {};
  config.agents.defaults = config.agents.defaults || {};
  if (config.agents.defaults.model !== CLAUDE_VIA_OPENROUTER) {
    config.agents.defaults.model = CLAUDE_VIA_OPENROUTER;
    console.log("[entrypoint] set agents.defaults.model to Claude via OpenRouter:", CLAUDE_VIA_OPENROUTER);
    updated = true;
  }
} else {
  console.warn("[entrypoint] WARNING: Neither ANTHROPIC_API_KEY nor OPENROUTER_API_KEY is set. Default model not configured.");
}

// Pin heartbeat to a free OpenRouter model so it never consumes paid credits.
const FREE_HEARTBEAT_MODEL = "openrouter/meta-llama/llama-3.1-8b-instruct:free";
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.heartbeat = config.agents.defaults.heartbeat || {};
if (config.agents.defaults.heartbeat.model !== FREE_HEARTBEAT_MODEL) {
  config.agents.defaults.heartbeat.model = FREE_HEARTBEAT_MODEL;
  console.log("[entrypoint] set agents.defaults.heartbeat.model to free model:", FREE_HEARTBEAT_MODEL);
  updated = true;
}

// Note: memory-core is enabled via the Control UI (Plugins tab), not via config injection.

if (updated) {
  fs.writeFileSync(configFile, JSON.stringify(config, null, 2));
  console.log("[entrypoint] updated config in", configFile);
}
EOF

# Launch gateway
echo "[entrypoint] Launching OpenClaw Gateway..."
if [ "$(id -u)" = '0' ]; then
  echo "[entrypoint] Running as root. Fixing permissions for /home/node..."
  chown -R node:node /home/node
  # Execute as node user. Use -m to preserve HOME and other env vars (like PORT, OPENROUTER_API_KEY).
  exec su -m node -s /bin/sh -c "node openclaw.mjs gateway run --allow-unconfigured"
else
  exec node openclaw.mjs gateway run --allow-unconfigured
fi
