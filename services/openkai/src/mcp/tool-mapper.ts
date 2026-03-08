import type { ClaudeTool } from '../intelligence/claude-client.js';

/**
 * Defines Claude tools that map to Sure's REST API endpoints.
 *
 * Instead of dynamically discovering tools via MCP, we define them
 * statically — we know exactly what endpoints exist and what they accept.
 *
 * These tools describe the REST API to Claude so it can request
 * financial data during conversations.
 */

const TOOLS: ClaudeTool[] = [
  {
    name: 'get_transactions',
    description: `Search the user's transactions with filters. Returns paginated results with amount, date, category, merchant, account, and tags.

Use this for:
- Finding specific transactions ("what did I spend at Target?")
- Filtering by date range, category, merchant, amount
- Getting recent spending data

Filters can be combined. Results include pagination info.

Note: amounts follow accounting convention — positive = expense, negative = income.`,
    input_schema: {
      type: 'object',
      properties: {
        start_date: {
          type: 'string',
          description: 'Start date in YYYY-MM-DD format',
        },
        end_date: {
          type: 'string',
          description: 'End date in YYYY-MM-DD format',
        },
        search: {
          type: 'string',
          description: 'Search by transaction name, notes, or merchant name',
        },
        category_id: {
          type: 'string',
          description: 'Filter by category ID',
        },
        merchant_id: {
          type: 'string',
          description: 'Filter by merchant ID',
        },
        account_id: {
          type: 'string',
          description: 'Filter by account ID',
        },
        type: {
          type: 'string',
          enum: ['income', 'expense'],
          description: 'Filter by transaction type',
        },
        min_amount: {
          type: 'string',
          description: 'Minimum amount filter',
        },
        max_amount: {
          type: 'string',
          description: 'Maximum amount filter',
        },
        page: {
          type: 'string',
          description: 'Page number (default: 1)',
        },
        per_page: {
          type: 'string',
          description: 'Results per page (default: 25, max: 100)',
        },
      },
    },
  },
  {
    name: 'get_accounts',
    description: `Get the user's financial accounts with their current balances.

Returns all visible accounts: checking, savings, credit cards, investments, loans, properties, crypto.

Each account includes: name, balance (formatted), currency, classification (asset/liability), account type, and pagination info.

Use this to:
- See what accounts the user has
- Get current balances
- Understand the user's financial overview`,
    input_schema: {
      type: 'object',
      properties: {
        page: {
          type: 'string',
          description: 'Page number (default: 1)',
        },
        per_page: {
          type: 'string',
          description: 'Results per page (default: 25, max: 100)',
        },
      },
    },
  },
  {
    name: 'get_holdings',
    description: `Get the user's investment holdings (stocks, ETFs, crypto).

Returns holdings from Investment and Crypto accounts with: ticker, name, quantity, price, total value, weight (allocation %), average cost, and account name.

Supports filtering by account and date range.

Use this for:
- Portfolio composition questions
- Investment performance
- Checking specific stock/crypto holdings`,
    input_schema: {
      type: 'object',
      properties: {
        account_id: {
          type: 'string',
          description: 'Filter by account ID',
        },
        start_date: {
          type: 'string',
          description: 'Start date in YYYY-MM-DD format',
        },
        end_date: {
          type: 'string',
          description: 'End date in YYYY-MM-DD format',
        },
        page: {
          type: 'string',
          description: 'Page number (default: 1)',
        },
        per_page: {
          type: 'string',
          description: 'Results per page (default: 25, max: 100)',
        },
      },
    },
  },
  {
    name: 'get_categories',
    description: `Get the user's transaction categories.

Returns the category tree: name, classification (income/expense), and subcategories.

Use this to:
- Look up category IDs for filtering transactions
- Understand the user's category structure
- Find the right category when the user says "groceries" or "restaurants"`,
    input_schema: {
      type: 'object',
      properties: {
        classification: {
          type: 'string',
          enum: ['income', 'expense'],
          description: 'Filter by income or expense categories',
        },
        roots_only: {
          type: 'string',
          enum: ['true', 'false'],
          description: 'Only return top-level categories (no subcategories)',
        },
        page: {
          type: 'string',
          description: 'Page number (default: 1)',
        },
        per_page: {
          type: 'string',
          description: 'Results per page (default: 25, max: 100)',
        },
      },
    },
  },
  {
    name: 'get_merchants',
    description: `Get the user's merchants (stores, services, etc. they transact with).

Use this to look up merchant IDs for filtering transactions by merchant.`,
    input_schema: {
      type: 'object',
      properties: {
        page: {
          type: 'string',
          description: 'Page number (default: 1)',
        },
        per_page: {
          type: 'string',
          description: 'Results per page (default: 25, max: 100)',
        },
      },
    },
  },
  {
    name: 'get_tags',
    description: `Get the user's transaction tags.

Use this to look up tag IDs for filtering transactions by tag.`,
    input_schema: {
      type: 'object',
      properties: {
        page: {
          type: 'string',
          description: 'Page number (default: 1)',
        },
        per_page: {
          type: 'string',
          description: 'Results per page (default: 25, max: 100)',
        },
      },
    },
  },
];

export class ToolMapper {
  private tools: ClaudeTool[] = TOOLS;

  /**
   * Get tools in Claude's format for passing to messages.create().
   */
  getClaudeTools(): ClaudeTool[] {
    return this.tools;
  }

  /**
   * Check if a tool name is in our known set.
   */
  hasTool(name: string): boolean {
    return this.tools.some((t) => t.name === name);
  }
}
