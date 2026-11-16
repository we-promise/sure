class TruelayerAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  KINDS = %w[account card].freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :truelayer_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_kind, inclusion: { in: KINDS }
  validates :account_id, uniqueness: { scope: :truelayer_item_id, allow_nil: true }

  # The id Sure stores as "truelayer_<id>" and dedupes on. TrueLayer's
  # transaction_id can change when a bank amends a transaction, while
  # normalised_provider_transaction_id is documented as stable, so prefer it.
  def self.transaction_id_for(transaction)
    transaction = transaction.with_indifferent_access
    transaction[:normalised_provider_transaction_id].to_s.strip.presence || transaction[:transaction_id].to_s.presence
  end

  # Display name for each account in one connection, keyed by account_id.
  #
  # Multi-currency providers (e.g. Wise) give every currency balance the
  # account holder's name, which can't tell them apart. When a connection
  # repeats a name, its current accounts are named after the bank and currency
  # instead, e.g. "Wise (USD)", keeping the original name as a suffix if two
  # share a currency. Cards keep their name plus the last digits.
  # `institution` overrides the per-account provider name, which can be the
  # provider's legal name in capitals.
  def self.display_names(snapshots, institution: nil)
    snapshots = snapshots.map(&:with_indifferent_access)
    base_names = snapshots.to_h { |s| [ s[:account_id].to_s, base_name(s) ] }
    repeats_names = base_names.values.tally.values.any? { |count| count > 1 }
    current_accounts = snapshots.reject { |s| s[:kind] == "card" }
    currency_counts = current_accounts.map { |s| s[:currency] }.tally

    snapshots.to_h do |s|
      id = s[:account_id].to_s
      name = base_names[id]
      bank = institution.presence || s.dig(:provider, :display_name)
      next [ id, name ] if !repeats_names || s[:kind] == "card" || bank.blank?

      base = "#{bank} (#{s[:currency]})"
      [ id, currency_counts[s[:currency]].to_i > 1 ? "#{base} #{name}" : base ]
    end
  end

  def self.base_name(snapshot)
    name = snapshot[:display_name].to_s.strip.presence || snapshot[:account_type].to_s.titleize.presence || "Account"
    digits = snapshot[:partial_card_number].to_s.strip
    snapshot[:kind] == "card" && digits.present? ? "#{name} ••#{digits}" : name
  end

  # Patterns in the bank's name for an account that suggest a depository
  # subtype, used to preselect one in the setup dialog.
  DEPOSITORY_SUBTYPE_HINTS = {
    "checking" => /\bchecking\b|\bchequing\b|\bcurrent\b|\bck\b|demand\s+deposit/,
    "savings" => /\bsavings?\b|\bsv\b/,
    "money_market" => /money\s+market|\bmm\b/
  }.freeze

  def card?
    account_kind == "card"
  end

  def suggested_depository_subtype
    DEPOSITORY_SUBTYPE_HINTS.find { |_, pattern| name.to_s.downcase.match?(pattern) }&.first
  end

  def current_account
    account
  end

  def upsert_truelayer_snapshot!(snapshot, display_name: nil, institution: nil)
    snapshot = snapshot.with_indifferent_access
    institution = institution.presence || snapshot.dig(:provider, :display_name)
    name = display_name.presence || self.class.base_name(snapshot)

    assign_attributes(
      account_id: snapshot[:account_id].to_s,
      account_kind: snapshot[:kind] == "card" ? "card" : "account",
      account_type: snapshot[:kind] == "card" ? snapshot[:card_type] : snapshot[:account_type],
      # Sure shows "<institution> - <name>" unless the name already starts
      # with the institution, so "Wise (USD)" isn't shown as "Wise - Wise (USD)".
      name: institution.present? && !name.downcase.start_with?(institution.downcase) ? "#{institution} - #{name}" : name,
      currency: parse_currency(snapshot[:currency]) || parse_currency(currency) || "GBP",
      provider: snapshot.dig(:provider, :provider_id),
      institution_metadata: {
        name: institution,
        logo: snapshot.dig(:provider, :logo_uri)
      }.compact,
      raw_payload: snapshot
    )
    save!
  end

  # Merges freshly fetched transactions into the stored set, keyed by
  # transaction id, so history fetched right after consent survives later,
  # narrower syncs. Pending transactions are skipped: their ids change once
  # they book.
  def merge_truelayer_transactions!(transactions)
    merged = Array(raw_transactions_payload).index_by { |t| self.class.transaction_id_for(t) }
    transactions.each do |transaction|
      next if transaction[:status].to_s == "pending"

      id = self.class.transaction_id_for(transaction)
      merged[id] = transaction if id.present?
    end

    update!(raw_transactions_payload: merged.values.sort_by { |t| t.with_indifferent_access[:timestamp].to_s })
  end

  # TrueLayer's `current` balance: what the account holds, or for a card the
  # amount owed (positive), which is already Sure's sign for a liability.
  def apply_balance!(amount, currency_code)
    update!(current_balance: amount, currency: parse_currency(currency_code) || currency)
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for TrueLayer account #{id}, defaulting to GBP")
    end
end
