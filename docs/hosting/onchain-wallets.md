# Setting Up On-Chain Wallets (Etherscan / Mempool.space)

Sure supports self-custody wallet tracking for **Bitcoin** and **Ethereum** (including ERC-20 tokens). This guide explains how to configure the required API keys for self-hosted deployments.

## Bitcoin (Mempool.space)

Bitcoin wallet tracking uses the public [mempool.space](https://mempool.space) API. **No API key is required.** Rate limits are handled automatically with client-side throttling and retry-with-backoff.

## Ethereum (Etherscan)

Ethereum wallet tracking requires an Etherscan API key.

### 1. Create an Etherscan Account

1. Go to [https://etherscan.io/register](https://etherscan.io/register) and create a free account.
2. After confirming your email, go to [https://etherscan.io/myapikey](https://etherscan.io/myapikey).
3. Click **Add** to create a new API key.
4. Copy the generated key.

### 2. Configure in Sure

The Etherscan API key is configured **per-family** through the Sure UI:

1. Log in to your Sure instance.
2. Navigate to **Settings > Providers > On-chain Wallets**.
3. Paste your Etherscan API key in the "Etherscan API Key" field.
4. Click **Save**.

### Security Notes

- The API key is encrypted at rest using Rails encrypted attributes (`encrypts :etherscan_api_key, deterministic: true`). The database column stores ciphertext, not plaintext.
- The key is never logged or exposed in error messages.
- Each family can have their own key, or multiple families can share a key by entering the same value.

### Rate Limits

Etherscan's free tier allows **5 calls/second** (the provider uses a conservative 0.4s interval between requests). If rate-limited, the provider retries with exponential backoff (up to 3 retries). For heavy usage (many wallets with many tokens), consider upgrading to an Etherscan Pro plan.

### Environment Variable (Optional)

There is no global environment variable for the Etherscan key — it is stored per-family in the database. This is by design: in multi-family deployments, each family manages their own provider credentials.

If you want all families to use a shared key, enter the same key in each family's provider settings.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Etherscan API key is required" | Add your key in Settings > Providers > On-chain Wallets |
| "Max rate limit reached" errors | The provider retries automatically; if persistent, wait a few minutes or upgrade your Etherscan plan |
| "No Ethereum balance or transactions found" | Verify the wallet address is correct and has on-chain activity |
| Bitcoin address errors | Ensure the address starts with `bc1`, `1`, or `3` (legacy, SegWit, or native SegWit formats) |
