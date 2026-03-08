/**
 * REST API client for Sure's /api/v1/ endpoints.
 *
 * Replaces the MCP JSON-RPC client. Instead of calling Sure's MCP
 * (which triggers another LLM), we call the REST API directly and
 * let Claude reason over the raw data.
 *
 * Auth: X-Api-Key header with a per-family or shared API key.
 * All requests go through Pipelock reverse proxy for security scanning.
 */

export interface SureApiConfig {
  baseUrl: string;   // e.g. "http://pipelock:8889" or "http://web:3000"
  apiKey: string;    // Sure API key (X-Api-Key header)
}

export interface ApiResponse<T = unknown> {
  ok: boolean;
  status: number;
  data: T;
  error?: string;
}

export class SureClient {
  private baseUrl: string;
  private apiKey: string;

  constructor(config: SureApiConfig) {
    this.baseUrl = config.baseUrl.replace(/\/+$/, '');
    this.apiKey = config.apiKey;
  }

  get available(): boolean {
    return this.baseUrl.length > 0 && this.apiKey.length > 0;
  }

  /**
   * Verify the API connection by hitting accounts endpoint.
   */
  async initialize(): Promise<void> {
    const res = await this.get('/api/v1/accounts', { per_page: '1' });
    if (!res.ok) {
      throw new Error(`Sure API connection failed (${res.status}): ${res.error}`);
    }
    console.log('[sure-api] Connection verified');
  }

  // --- Financial data endpoints ---

  /**
   * GET /api/v1/transactions with filters.
   */
  async getTransactions(params: Record<string, string | string[]> = {}): Promise<ApiResponse> {
    return this.get('/api/v1/transactions', this.flattenParams(params));
  }

  /**
   * GET /api/v1/accounts
   */
  async getAccounts(params: Record<string, string> = {}): Promise<ApiResponse> {
    return this.get('/api/v1/accounts', params);
  }

  /**
   * GET /api/v1/holdings with filters.
   */
  async getHoldings(params: Record<string, string | string[]> = {}): Promise<ApiResponse> {
    return this.get('/api/v1/holdings', this.flattenParams(params));
  }

  /**
   * GET /api/v1/categories
   */
  async getCategories(params: Record<string, string> = {}): Promise<ApiResponse> {
    return this.get('/api/v1/categories', params);
  }

  /**
   * GET /api/v1/merchants
   */
  async getMerchants(params: Record<string, string> = {}): Promise<ApiResponse> {
    return this.get('/api/v1/merchants', params);
  }

  /**
   * GET /api/v1/tags
   */
  async getTags(params: Record<string, string> = {}): Promise<ApiResponse> {
    return this.get('/api/v1/tags', params);
  }

  /**
   * Generic tool dispatcher — called from chat-completions when Claude uses a tool.
   * Maps tool name → REST API call.
   */
  async callTool(name: string, args: Record<string, unknown>): Promise<unknown> {
    const params = this.flattenParams(this.toStringParams(args));

    switch (name) {
      case 'get_transactions':
        return (await this.getTransactions(params)).data;

      case 'get_accounts':
        return (await this.getAccounts(params)).data;

      case 'get_holdings':
        return (await this.getHoldings(params)).data;

      case 'get_categories':
        return (await this.getCategories(params)).data;

      case 'get_merchants':
        return (await this.getMerchants(params)).data;

      case 'get_tags':
        return (await this.getTags(params)).data;

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  }

  // --- HTTP transport ---

  private async get(path: string, params: Record<string, string> = {}): Promise<ApiResponse> {
    const url = new URL(`${this.baseUrl}${path}`);
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== '') {
        url.searchParams.append(key, value);
      }
    }

    const response = await fetch(url.toString(), {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'X-Api-Key': this.apiKey,
      },
    });

    if (!response.ok) {
      const text = await response.text();
      return {
        ok: false,
        status: response.status,
        data: null,
        error: `HTTP ${response.status}: ${text}`,
      };
    }

    const data = await response.json();
    return { ok: true, status: response.status, data };
  }

  /**
   * Convert Claude's tool args (mixed types) to string params for query strings.
   * Arrays become repeated params (e.g., account_ids[]=1&account_ids[]=2).
   */
  private toStringParams(args: Record<string, unknown>): Record<string, string | string[]> {
    const result: Record<string, string | string[]> = {};
    for (const [key, value] of Object.entries(args)) {
      if (value === null || value === undefined) continue;
      if (Array.isArray(value)) {
        result[key] = value.map(String);
      } else {
        result[key] = String(value);
      }
    }
    return result;
  }

  /**
   * Flatten array params into repeated query string params.
   * { category_ids: ["1", "2"] } → { "category_ids[]": "1", "category_ids[]": "2" }
   * Actually, we append them as separate entries via URLSearchParams.
   */
  private flattenParams(params: Record<string, string | string[]>): Record<string, string> {
    const flat: Record<string, string> = {};
    for (const [key, value] of Object.entries(params)) {
      if (Array.isArray(value)) {
        // URLSearchParams handles this via multiple .append() calls in get()
        // For simplicity, join with comma — Rails can handle both formats
        flat[key] = value.join(',');
      } else {
        flat[key] = value;
      }
    }
    return flat;
  }
}
