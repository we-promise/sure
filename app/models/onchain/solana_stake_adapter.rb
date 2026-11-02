# frozen_string_literal: true

# A single Solana stake account, read directly — not a wallet's delegated
# positions. A delegated SOL position lives in its own on-chain "stake
# account", not the wallet address that owns it, so it never shows up in
# Onchain::SolanaAdapter's normal balance/token-account read. Discovering
# every stake account owned by a wallet needs `getProgramAccounts` on the
# Stake program, and public RPCs refuse that call without a paid key. That's
# a hard wall for a keyless adapter, the same category of constraint
# Onchain::BitcoinAdapter already documents for xpubs: this reads one stake
# account at a time, given directly, the same way Bitcoin here reads one
# address at a time instead of deriving a whole HD wallet.
#
# The address this adapter takes is the stake account's own address, the
# same object model as any other Solana account, not the wallet that funded
# or controls it.
#
# No token concept applies (a stake account holds SOL, nothing else), so —
# like Avalanche's P-Chain and Bitcoin — only a native quantity is reported.
#
# History: there's no cheap way to read a stake account's activity from a
# public endpoint either (its own transaction history mixes delegate/
# deactivate/withdraw instructions with no simple amount-per-entry meaning
# the way a token transfer has), so movements are not implemented — reports
# balance only, same degrade path as the P-Chain adapter.
class Onchain::SolanaStakeAdapter
  include Onchain::ChainAdapter

  LAMPORTS_PER_SOL = 1_000_000_000.to_d

  # Same Base58 shape as a normal Solana address - a stake account is an
  # ordinary account, just one whose owner happens to be the Stake program.
  # Onchain::SolanaAdapter's own comment on this pattern applies here too:
  # shorter encodings than the usual 43-44 chars are legal.
  ADDRESS_PATTERN = /\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  # A stake account's address is indistinguishable in *format* from a normal
  # Solana wallet address - valid_address? alone can't tell them apart, so
  # unlike every format-unique adapter (Bitcoin, Avalanche's P-Chain), this
  # one has to actually ask the chain which kind it is, the same way
  # Onchain::EvmAdapter must for every EVM network sharing the 0x shape.
  # One request, on the request thread, same contract as every other
  # has_activity? override in this app.
  def has_activity?(address)
    return false unless valid_address?(address)

    info = detection_provider.get_account_info(address)
    return false if info.nil?

    info["owner"] == Provider::SolanaRpc::STAKE_PROGRAM_ID
  rescue StandardError => e
    Rails.logger.warn("Onchain::SolanaStakeAdapter - activity probe failed: #{e.class}")
    nil
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid Solana address" unless valid_address?(address)

    wrap_provider_errors do
      info = provider.get_account_info(address)
      raise Onchain::Chains::Error, "Account not found" if info.nil?
      unless info["owner"] == Provider::SolanaRpc::STAKE_PROGRAM_ID
        raise Onchain::Chains::Error, "This address is not a Solana stake account"
      end

      quantity = info["lamports"].to_d / LAMPORTS_PER_SOL

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: quantity) ],
        movements: [],
        history_truncated: true
      )
    end
  end

  def provider_error_classes
    [ Provider::SolanaRpc::RateLimitError, Provider::SolanaRpc::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::SOLANA_STAKE)
    end

    def provider
      @provider ||= Provider::SolanaRpc.new
    end

    # Same reasoning as Onchain::SolanaAdapter's own detection_provider: this
    # runs on the request thread during chain detection, not the sync's, so
    # it gets the shorter detection budget instead of the sync's patience.
    def detection_provider
      @detection_provider ||= Provider::SolanaRpc.new(
        request_timeout: Onchain::DetectionBudget.timeout,
        max_retries: Onchain::DetectionBudget.retries
      )
    end
end
