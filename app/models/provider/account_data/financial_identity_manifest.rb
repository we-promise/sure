# Reviewed legacy Entry identities. These rules classify persisted IDs; they
# never reconstruct an ID from money, dates, labels, raw exports or API calls.
class Provider::AccountData::FinancialIdentityManifest
  VERSION = 1
  Rule = Data.define(:pattern, :kind, :entryable_types)
  TRANSACTION_PROVIDERS = %w[akahu brex enable_banking lunchflow mercury monobank redbark simplefin sophtron up wise].freeze
  ACTIVITY_PROVIDERS = %w[binance coinbase coinstats ibkr indexa_capital onchain_wallet questrade snaptrade trade_republic trading212].freeze
  PROVIDER_KEYS = (TRANSACTION_PROVIDERS + ACTIVITY_PROVIDERS + %w[kraken plaid]).sort.freeze
  ARCHIVE_COLUMNS = {
    "akahu" => %w[raw_transactions_payload], "binance" => %w[raw_transactions_payload],
    "brex" => %w[raw_transactions_payload], "coinbase" => %w[raw_transactions_payload],
    "coinstats" => %w[raw_transactions_payload], "enable_banking" => %w[raw_transactions_payload],
    "ibkr" => %w[raw_activities_payload], "indexa_capital" => %w[raw_activities_payload],
    "kraken" => %w[raw_transactions_payload], "lunchflow" => %w[raw_transactions_payload],
    "mercury" => %w[raw_transactions_payload], "monobank" => %w[raw_transactions_payload],
    "onchain_wallet" => %w[raw_movements_payload], "plaid" => %w[raw_transactions_payload raw_holdings_payload],
    "questrade" => %w[raw_activities_payload], "redbark" => %w[raw_transactions_payload],
    "simplefin" => %w[raw_transactions_payload], "snaptrade" => %w[raw_activities_payload raw_transactions_payload],
    "sophtron" => %w[raw_transactions_payload], "trade_republic" => %w[raw_timeline_payload],
    "trading212" => %w[raw_orders_payload raw_dividends_payload raw_transactions_payload], "up" => %w[raw_transactions_payload],
    "wise" => %w[raw_transactions_payload]
  }.transform_values { |values| values.map(&:freeze).freeze }.freeze

  attr_reader :provider_key

  def self.for(provider_key)
    raise ArgumentError, "Unreviewed financial identity provider" unless PROVIDER_KEYS.include?(provider_key)
    new(provider_key)
  end
  private_class_method :new

  def initialize(provider_key)
    @provider_key = provider_key.dup.freeze
    freeze
  end

  def source
    provider_key
  end

  def legacy_manifest
    Provider::AccountData::MigrationManifest.for(provider_key)
  end

  def specialized?
    provider_key == "plaid"
  end

  def archive_columns
    ARCHIVE_COLUMNS.fetch(provider_key)
  end

  # Include recognizable IDs with a missing/conflicting source as review blockers.
  # Unprefixed Indexa/SnapTrade IDs cannot attribute an otherwise manual Entry.
  def candidate_prefixes
    return [] if %w[indexa_capital snaptrade plaid].include?(provider_key)
    [ provider_key == "onchain_wallet" ? "onchain_" : "#{provider_key}_" ]
  end

  def rule_for(id, legacy_account_id:)
    return unless id.is_a?(String) && id.present?
    rules(legacy_account_id).find { |rule| rule.pattern.match?(id) }
  end

  # Legacy allocation depends on earlier persisted collisions, whereas native
  # occurrence is the position in one response. A suffix is not that provenance.
  def occurrence_base(id)
    return unless %w[akahu lunchflow].include?(provider_key)
    match = /\A(#{Regexp.escape(provider_key)}_pending_[0-9a-f]{32})(?:_[0-9]+)?\z/.match(id)
    match && match[1]
  end

  def inspect
    "#<#{self.class.name} provider=#{provider_key} version=#{VERSION}>"
  end

  private
    def rules(legacy_account_id)
      case provider_key
      when "plaid" then [] # Older plaid_id and banking/activity ambiguity need its specialized planner.
      when "wise"
        [ rule(/\Awise_(?:transfer|fee|statement|activity|interbalance)_.+\z/m, "transaction", "Transaction") ]
      when *TRANSACTION_PROVIDERS
        [ rule(/\A#{Regexp.escape(provider_key)}_.+\z/m, "transaction", "Transaction") ]
      when "binance"
        [ rule(/\Abinance_(?:spot|futures)_.+_.+\z/m, "activity", "Trade"),
          rule(/\Abinance_p2p_.+_funding\z/m, "activity", "Transaction"), rule(/\Abinance_p2p_.+\z/m, "activity", "Trade") ]
      when "coinbase"
        [ rule(/\Acoinbase_(?:txn|buy|sell)_.+\z/m, "activity", "Trade") ]
      when "coinstats"
        [ rule(/\Acoinstats_.+\z/m, "activity", "Transaction", "Trade") ]
      when "ibkr"
        [ rule(/\Aibkr_trade_fee_.+\z/m, "activity", "Transaction"), rule(/\Aibkr_cash_.+\z/m, "activity", "Transaction"),
          rule(/\Aibkr_trade_.+\z/m, "activity", "Trade") ]
      when "indexa_capital", "snaptrade"
        [ rule(/\A.+\z/m, "activity", "Transaction", "Trade") ]
      when "kraken"
        [ rule(/\Akraken_ledger_.+\z/m, "transaction", "Transaction"), rule(/\Akraken_trade_.+\z/m, "activity", "Trade") ]
      when "onchain_wallet"
        [ rule(/\Aonchain_#{Regexp.escape(legacy_account_id)}_.+\z/m, "activity", "Trade") ]
      when "questrade"
        [ rule(/\Aquestrade_(?:trade|journal)_[0-9a-f]{24}\z/, "activity", "Trade"),
          rule(/\Aquestrade_(?:cash|fee)_[0-9a-f]{24}\z/, "activity", "Transaction") ]
      when "trade_republic"
        [ rule(/\Atrade_republic_event_.+\z/m, "activity", "Transaction", "Trade") ]
      when "trading212"
        [ rule(/\Atrading212_order_.+\z/m, "activity", "Trade"),
          rule(/\Atrading212_(?:dividend|transaction)_.+\z/m, "activity", "Transaction") ]
      else
        raise ArgumentError, "Financial identity rules are incomplete"
      end
    end

    def rule(pattern, kind, *types)
      Rule.new(pattern: pattern.freeze, kind: kind.freeze, entryable_types: types.map(&:freeze).freeze)
    end
end
