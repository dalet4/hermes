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
const railwayPublicDomain = process.env.RAILWAY_PUBLIC_DOMAIN;
if (railwayPublicDomain) {
  const railwayOrigin = "https://" + railwayPublicDomain;
  const existing = config.gateway.controlUi.allowedOrigins || [];
  if (!existing.includes(railwayOrigin)) {
    config.gateway.controlUi.allowedOrigins = [...existing, railwayOrigin];
    console.log("[entrypoint] set gateway.controlUi.allowedOrigins to include " + railwayOrigin);
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

// On Railway: bind to 0.0.0.0 so the proxy can reach the gateway.
// The gateway refuses to bind to non-loopback without a shared secret,
// so we also inject OPENCLAW_GATEWAY_TOKEN as the auth token.
// Railway also injects PORT (usually 8080) and expects the app to listen there.
const gatewayToken = process.env.OPENCLAW_GATEWAY_TOKEN;
const railwayPort = process.env.PORT ? parseInt(process.env.PORT, 10) : null;
const isRailway = process.env.RAILWAY_ENVIRONMENT || process.env.RAILWAY_SERVICE_NAME || process.env.RAILWAY_ENVIRONMENT_ID || process.env.RAILWAY_SERVICE_ID;
if (isRailway) {
  if (config.gateway.bind !== "lan") {
    config.gateway.bind = "lan";
    console.log("[entrypoint] Railway detected: set gateway.bind = lan (0.0.0.0)");
    updated = true;
  }
  if (railwayPort && config.gateway.port !== railwayPort) {
    config.gateway.port = railwayPort;
    console.log(`[entrypoint] Railway detected: set gateway.port = ${railwayPort} (from PORT env var)`);
    updated = true;
  }
  if (config.gateway.suppressSecurityWarnings !== true) {
    config.gateway.suppressSecurityWarnings = true;
    console.log("[entrypoint] Railway detected: set gateway.suppressSecurityWarnings = true");
    updated = true;
  }
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
    console.log("[entrypoint] Railway detected: added internal ranges to gateway.trustedProxies");
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

// Inject OPENROUTER_API_KEY into config.env (the canonical location per docs)
// and also into models.providers.openrouter.apiKey for legacy compat.
const openrouterKey = process.env.OPENROUTER_API_KEY;
if (openrouterKey) {
  config.env = config.env || {};
  if (config.env.OPENROUTER_API_KEY !== openrouterKey) {
    config.env.OPENROUTER_API_KEY = openrouterKey;
    console.log("[entrypoint] injected OPENROUTER_API_KEY into config.env.OPENROUTER_API_KEY");
    updated = true;
  }
  config.models = config.models || {};
  config.models.providers = config.models.providers || {};
  config.models.providers.openrouter = config.models.providers.openrouter || {};
  if (config.models.providers.openrouter.apiKey !== openrouterKey) {
    config.models.providers.openrouter.apiKey = openrouterKey;
    console.log("[entrypoint] injected OPENROUTER_API_KEY into models.providers.openrouter.apiKey");
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
