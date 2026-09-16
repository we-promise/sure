# frozen_string_literal: true

# Normalises an on-chain token symbol to the asset a price provider knows.
#
# The same dollar is called USDC on Ethereum, USDC.e on Arbitrum and USDbC on
# Base; the same ether is ETH natively and WETH once wrapped. Left alone, each
# variant becomes its own Security: one of them gets priced and the others sit
# at zero, and a portfolio holding "the same" asset on two chains reports two
# different values.
class Onchain::AssetSymbol
  # Bridged or wrapped forms that are redeemable 1:1 for the canonical asset, so
  # pricing them as the canonical asset is exact rather than an approximation.
  ALIASES = {
    "USDT0"   => "USDT",  # LayerZero-bridged USDT
    "USDBC"   => "USDC",  # Base's bridged USDC
    "AXLUSDC" => "USDC",  # Axelar-bridged USDC
    "WETH"    => "ETH",
    "WSOL"    => "SOL",
    "WPOL"    => "POL",
    "WMATIC"  => "POL",   # MATIC was renamed POL
    "WXDAI"   => "XDAI"
  }.freeze

  # Bridge markers appended by Avalanche and Arbitrum: USDC.e, BTC.b
  BRIDGE_SUFFIX = /\.(?:E|B)\z/

  def self.canonical(symbol)
    normalized = symbol.to_s.strip.upcase
    return normalized if normalized.empty?

    normalized = normalized.sub(BRIDGE_SUFFIX, "")
    ALIASES.fetch(normalized, normalized)
  end
end
