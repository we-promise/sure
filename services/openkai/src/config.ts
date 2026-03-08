import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import TOML from '@iarna/toml';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(__dirname, '..');

// --- Interfaces ---

export interface DaemonConfig {
  name: string;
  version: string;
  log_level: 'debug' | 'info' | 'warn' | 'error';
}

export interface ApiConfig {
  host: string;
  port: number;
}

export interface ClaudeConfig {
  default_model: string;
  complex_model: string;
  extraction_model: string; // Cheap model for memory extraction + dedup (Haiku)
  daily_budget_usd: number;
  per_family_daily_budget_usd: number;
  timeout_ms: number;
  api_key?: string;
}

export interface MemoryConfig {
  max_cached_tenants: number;
  data_dir: string;
}

export interface SureApiConfig {
  baseUrl: string;   // Sure's REST API base URL (e.g. "http://pipelock:8889" or "http://web:3000")
  apiKey: string;    // Sure API key (X-Api-Key header)
}

export interface RoutingConfig {
  moderate: string;
  complex: string;
}

export interface PricingEntry {
  input: number;
  output: number;
}

export interface Config {
  daemon: DaemonConfig;
  api: ApiConfig;
  claude: ClaudeConfig;
  memory: MemoryConfig;
  sureApi: SureApiConfig;
  routing: RoutingConfig;
  pricing: Record<string, PricingEntry>;
}

// --- Loader ---

export function loadConfig(): Config {
  const defaultPath = resolve(PROJECT_ROOT, 'config/default.toml');
  const modelsPath = resolve(PROJECT_ROOT, 'config/models.toml');

  const defaultToml = TOML.parse(readFileSync(defaultPath, 'utf-8')) as Record<string, any>;

  let modelsToml: Record<string, any> = {};
  if (existsSync(modelsPath)) {
    modelsToml = TOML.parse(readFileSync(modelsPath, 'utf-8')) as Record<string, any>;
  }

  // Environment variables override TOML config
  const config: Config = {
    daemon: defaultToml.daemon as DaemonConfig,
    api: {
      host: process.env.OPENKAI_HOST ?? (defaultToml.api as ApiConfig).host,
      port: parseInt(process.env.OPENKAI_PORT ?? String((defaultToml.api as ApiConfig).port), 10),
    },
    claude: {
      default_model: (defaultToml.claude as any).default_model,
      complex_model: (defaultToml.claude as any).complex_model,
      extraction_model: (defaultToml.claude as any).extraction_model ?? 'claude-haiku-4-5-20251001',
      daily_budget_usd: parseFloat(
        process.env.OPENKAI_DAILY_BUDGET_USD ?? String((defaultToml.claude as any).daily_budget_usd),
      ),
      per_family_daily_budget_usd: parseFloat(
        process.env.OPENKAI_PER_FAMILY_DAILY_BUDGET_USD ??
          String((defaultToml.claude as any).per_family_daily_budget_usd),
      ),
      timeout_ms: (defaultToml.claude as any).timeout_ms,
      api_key: process.env.ANTHROPIC_API_KEY,
    },
    memory: {
      max_cached_tenants: parseInt(
        process.env.OPENKAI_MAX_CACHED_TENANTS ??
          String((defaultToml.memory as any).max_cached_tenants),
        10,
      ),
      data_dir: process.env.OPENKAI_DATA_DIR ?? (defaultToml.memory as any).data_dir,
    },
    sureApi: {
      baseUrl: process.env.SURE_API_URL ?? (defaultToml.sure_api as any)?.base_url ?? 'http://web:3000',
      apiKey: process.env.SURE_API_KEY ?? '',
    },
    routing: (modelsToml.routing as RoutingConfig) ?? {
      moderate: 'claude-sonnet-4-20250514',
      complex: 'claude-opus-4-20250514',
    },
    pricing: buildPricingMap(modelsToml),
  };

  return config;
}

function buildPricingMap(modelsToml: Record<string, any>): Record<string, PricingEntry> {
  const pricing: Record<string, PricingEntry> = {};

  if (modelsToml.pricing) {
    for (const [key, value] of Object.entries(modelsToml.pricing)) {
      if (typeof value === 'object' && value !== null && 'input' in value && 'output' in value) {
        pricing[key] = value as PricingEntry;
      }
    }
  }

  // Defaults if not in TOML
  if (!pricing['claude-haiku-4-5-20251001']) {
    pricing['claude-haiku-4-5-20251001'] = { input: 0.8, output: 4 };
  }
  if (!pricing['claude-sonnet-4-20250514']) {
    pricing['claude-sonnet-4-20250514'] = { input: 3, output: 15 };
  }
  if (!pricing['claude-opus-4-20250514']) {
    pricing['claude-opus-4-20250514'] = { input: 15, output: 75 };
  }

  return pricing;
}

export function getProjectRoot(): string {
  return PROJECT_ROOT;
}
