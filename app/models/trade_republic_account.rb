class TradeRepublicAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include TradeRepublicAccount::DataHelpers

  if encryption_ready?
    encrypts :raw_positions_payload
    encrypts :raw_timeline_payload
  end

  belongs_to :trade_republic_item

  # The provider model can be loaded while Rails is booting before the
  # development schema cache has refreshed after a migration. Declaring the
  # type explicitly keeps the enum valid in that reload window as well.
  attribute :kind, :string, default: "portfolio"
  enum :kind, { portfolio: "portfolio", cash: "cash", crypto: "crypto", pea: "pea" }, default: :portfolio

  # Trade Republic lists crypto under pseudo-ISINs starting with XF000.
  CRYPTO_ISIN_PREFIX = "XF000"

  # Kinds that hold securities. The PEA holds its own cash too (French law keeps
  # sale proceeds and interest inside the wrapper), so it has no cash sibling.
  SECURITIES_KINDS = %w[portfolio pea crypto].freeze
  CASH_KINDS = %w[cash].freeze

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :currency, presence: true
  validates :trade_republic_account_id, uniqueness: { scope: :trade_republic_item_id, allow_nil: true }

  def self.crypto_isin?(isin)
    isin.to_s.strip.upcase.start_with?(CRYPTO_ISIN_PREFIX)
  end

  def self.crypto_position?(position)
    return false unless position.is_a?(Hash)

    position = position.with_indifferent_access
    position[:category].to_s == "crypto_wallet" || crypto_isin?(position[:isin])
  end

  def current_account
    account || linked_account
  end

  # The linked Sure account, unless it is being deleted or was disabled.
  def usable_account
    acct = current_account
    acct unless acct.nil? || acct.pending_deletion? || acct.disabled?
  end

  def sibling(kind)
    trade_republic_item.trade_republic_accounts.find_by(kind: kind)
  end

  # Manual accounts this provider account can be linked to. Crypto only
  # links to a Crypto exchange account, the Crypto subtype that supports
  # trades, or to an Investment account; Portfolio and Cash keep linking to
  # Investment and Depository accounts.
  def linkable_to?(account)
    case account.accountable_type
    when "Investment" then true
    when "Depository" then !crypto?
    when "Crypto" then crypto? && account.accountable&.subtype == "exchange"
    else false
    end
  end

  # Portfolio, PEA and Crypto accounts hold securities; the cash accounts
  # settle their trades.
  def holds_securities?
    SECURITIES_KINDS.include?(kind)
  end

  def cash_like?
    CASH_KINDS.include?(kind)
  end

  # DEFAULT envelope (CTO) vs the French PEA tax wrapper. Positions and trades
  # belong to one envelope each because the TR timeline is user-wide.
  def envelope_kind
    pea? ? "pea" : "portfolio"
  end

  # Accounts whose displayed cash comes from a dedicated cash pocket. The PEA
  # keeps its cash inside the securities account, so it is included here.
  def cash_holding?
    cash_like? || pea?
  end

  # Sibling that settles this account's trades. PEA settles internally, so it
  # returns nil and its trades/cash movements both book on the PEA account.
  def cash_sibling_kind
    pea? ? nil : "cash"
  end

  # Account whose stored timeline this account reads: the default cash account
  # and the Crypto account both take their events from the portfolio. The PEA
  # reads its own timeline.
  def securities_sibling_kind
    cash? || crypto? ? "portfolio" : nil
  end

  # Crypto moves to its own account once the user linked the Crypto account.
  # Until then the portfolio keeps holding it.
  def crypto_split?
    sibling("crypto")&.usable_account.present?
  end

  # Trade Republic returns crypto in the portfolio snapshot. The Crypto
  # account holds those positions; the portfolio keeps them only while no
  # Crypto account is linked.
  def positions
    case kind
    when "crypto"
      Array(sibling("portfolio")&.raw_positions_payload).select { |position| self.class.crypto_position?(position) }
    when "pea"
      Array(raw_positions_payload)
    when "portfolio"
      positions = Array(raw_positions_payload)
      crypto_split? ? positions.reject { |position| self.class.crypto_position?(position) } : positions
    else
      []
    end
  end

  def positions_snapshot_complete?
    crypto? ? sibling("portfolio")&.holdings_snapshot_complete? : holdings_snapshot_complete?
  end

  # current_balance on the portfolio values the whole snapshot, crypto
  # included, so a split portfolio leaves out what the Crypto account holds.
  # Sure reads an account's balance as the total, holdings plus cash (see
  # UI::Account::Chart#holdings_value_money), so the PEA - which keeps its cash
  # inside the account - reports snapshot value plus that cash pocket.
  def account_balance
    return (current_balance || 0).to_d - (sibling("crypto").current_balance || 0).to_d if portfolio? && crypto_split?
    return (current_balance || 0).to_d + (cash_balance || 0).to_d if pea?

    current_balance
  end

  def ensure_account_provider!(account = nil)
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "TradeRepublicAccount", provider_id: id)
      .tap do |record|
        record.account = acct
        record.save!
      end

    reload_account_provider
    provider
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "TradeRepublicAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "trade_republic",
      family: trade_republic_item.family,
      provider_key: "trade_republic"
    )
    nil
  end
end
