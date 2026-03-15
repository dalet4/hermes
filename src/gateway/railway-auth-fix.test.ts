import { describe, it, expect, beforeEach, afterEach } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import { resolveGatewayAuth } from "./auth.js";
import { resolveGatewayRuntimeConfig } from "./server-runtime-config.js";

describe("Railway Auth Fix", () => {
  const originalEnv = { ...process.env };

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it("should resolve auth mode from OPENCLAW_GATEWAY_AUTH_MODE", () => {
    const env = { OPENCLAW_GATEWAY_AUTH_MODE: "trusted-proxy" };
    const resolved = resolveGatewayAuth({
      authConfig: {},
      env,
    });
    expect(resolved.mode).toBe("trusted-proxy");
    expect(resolved.modeSource).toBe("env");
    expect(resolved.trustedProxy?.userHeader).toBe("X-Control-User");
  });

  it("should support custom user header from OPENCLAW_GATEWAY_TRUSTED_PROXY_USER_HEADER", () => {
    const env = {
      OPENCLAW_GATEWAY_AUTH_MODE: "trusted-proxy",
      OPENCLAW_GATEWAY_TRUSTED_PROXY_USER_HEADER: "X-Railway-Source-Ip",
    };
    const resolved = resolveGatewayAuth({
      authConfig: {},
      env,
    });
    expect(resolved.trustedProxy?.userHeader).toBe("X-Railway-Source-Ip");
  });

  it("should resolve trustedProxies from OPENCLAW_GATEWAY_TRUSTED_PROXIES", async () => {
    process.env.OPENCLAW_GATEWAY_TRUSTED_PROXIES = "1.2.3.4, 5.6.7.8";
    const runtimeConfig = await resolveGatewayRuntimeConfig({
      cfg: { gateway: { auth: { mode: "none" } } } as unknown as OpenClawConfig,
      port: 8080,
    });
    expect(runtimeConfig.trustedProxies).toEqual(["1.2.3.4", "5.6.7.8"]);
  });

  it("should resolve dangerouslyAllowHostHeaderOriginFallback from environment", async () => {
    process.env.OPENCLAW_GATEWAY_CONTROL_UI_DANGEROUSLY_ALLOW_HOST_HEADER_ORIGIN_FALLBACK = "true";
    const runtimeConfig = await resolveGatewayRuntimeConfig({
      cfg: { gateway: { auth: { mode: "none" } } } as unknown as OpenClawConfig,
      port: 8080,
    });
    expect(runtimeConfig.dangerouslyAllowHostHeaderOriginFallback).toBe(true);
  });
});
