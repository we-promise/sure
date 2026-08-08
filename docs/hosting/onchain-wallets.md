# Setting Up On-Chain Wallets

Sure supports self-custody wallet tracking for Bitcoin, Ethereum, Solana, Bittensor (TAO), and supported EVM chains. Wallet sync is read-only; wallet addresses and explorer API keys cannot move funds.

## Data Sources

- Bitcoin uses the public [mempool.space](https://mempool.space) API. No API key is required.
- Solana uses public RPC. No API key is required.
- Bittensor uses a public Finney Substrate RPC for free/liquid TAO balances. No API key is required. Override with `BITTENSOR_RPC_URL` if needed.
- Ethereum uses Blockscout by default. No API key is required.
- Polygon, Arbitrum, Optimism, Base, and Gnosis use Blockscout. No API key is required.
- Ethereum can optionally use Etherscan instead of Blockscout. This requires an Etherscan API key.

## Bittensor (TAO) notes

- Addresses are SS58 coldkeys (network prefix 42, typically 48 characters starting with `5`).
- Sync tracks **free/liquid TAO** only. Staked TAO and subnet α are not imported in this version.
- Transfer history is not indexed yet; the account balance and holding still update from the free balance.

## Configure Ethereum Source

The Ethereum data source is configured per family:

1. Log in to your Sure instance.
2. Navigate to **Settings > Providers > On-chain Wallets**.
3. Choose **Blockscout** or **Etherscan** as the Ethereum data source.
4. If choosing Etherscan, paste the Etherscan API key.
5. Click **Save**.

## Etherscan API Key

To use Etherscan for Ethereum:

1. Create an account at [https://etherscan.io/register](https://etherscan.io/register).
2. Open [https://etherscan.io/myapikey](https://etherscan.io/myapikey).
3. Create and copy an API key.
4. Enter it in **Settings > Providers > On-chain Wallets** after selecting Etherscan.

The Etherscan key is encrypted at rest with Rails encrypted attributes. There is no global environment variable for this key; each family configures it in the UI.

## Rate Limits

Blockscout and mempool.space calls are throttled client-side and retried when rate-limited. Etherscan calls use a conservative request interval and retry rate-limit responses with exponential backoff. For heavy Ethereum usage with Etherscan, consider an Etherscan paid plan. Public Bittensor RPC endpoints are also rate-limited; set `BITTENSOR_RPC_URL` to your own node if needed.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Etherscan API key can't be blank" | Choose Blockscout or add an Etherscan key in Settings > Providers > On-chain Wallets |
| Etherscan rate limit errors | Wait a few minutes, switch Ethereum back to Blockscout, or upgrade the Etherscan plan |
| No EVM balance, token holdings, or transactions found | Verify the address and selected chain have on-chain activity |
| Bitcoin address errors | Ensure the address starts with `bc1`, `1`, or `3` |
| Bittensor address errors | Ensure the address is a valid SS58 coldkey (usually starts with `5`, 48 characters) |
| No free TAO balance found | Confirm the coldkey has a free (unbonded) balance; staked TAO is not shown yet |
