class PlaidAccount < ApplicationRecord
  include Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    # Renamed from raw_investments_payload; rename_column keeps the stored ciphertext,
    # which decrypts under the new name because Active Record Encryption does not bind
    # ciphertext to the attribute name, so no `previous:` scheme is needed.
    encrypts :raw_holdings_payload
    encrypts :raw_liabilities_payload
  end

  belongs_to :plaid_item

  # Legacy association via foreign key (will be removed after migration)
  has_one :account, dependent: :nullify, foreign_key: :plaid_account_id
  # New association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :plaid_type, :currency, presence: true
  validates :plaid_id, uniqueness: { scope: :plaid_item_id }
  validate :has_balance

  # Helper to get account using new system first, falling back to legacy
  def current_account
    linked_account || account
  end

  def upsert_plaid_snapshot!(account_snapshot)
    assign_attributes(
      current_balance: account_snapshot.balances.current,
      available_balance: account_snapshot.balances.available,
      currency: account_snapshot.balances.iso_currency_code,
      plaid_type: account_snapshot.type,
      plaid_subtype: account_snapshot.subtype,
      name: account_snapshot.name,
      mask: account_snapshot.mask,
      raw_payload: account_snapshot
    )

    save!
  end

  def upsert_plaid_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  def upsert_plaid_holdings_snapshot!(holdings_snapshot)
    assign_attributes(
      raw_holdings_payload: holdings_snapshot
    )

    save!
  end

  def upsert_plaid_liabilities_snapshot!(liabilities_snapshot)
    assign_attributes(
      raw_liabilities_payload: liabilities_snapshot
    )

    save!
  end

  # The one date every holding of a holdings sync is written on, and the date
  # the balance anchor for that sync goes on.
  #
  # Plaid dates each holding by its own institution price date, so a fund
  # priced at the previous close sits a day or more behind the rest. The
  # quantities all describe the same moment, though, and "current holdings"
  # are read as the provider rows on one date, so a lagging row would drop out.
  # The snapshot is dated by the newest price date it carries. A date ahead of
  # today is discounted on its own, so one bad feed does not pull the snapshot
  # off the date the rest agree on; a snapshot with no usable date is today's.
  def holdings_snapshot_date
    holdings = raw_holdings_payload&.dig("holdings") || []
    dates = holdings.filter_map { |holding| parse_holding_date(holding["institution_price_as_of"]) }
    dates.reject { |date| date > Date.current }.max || Date.current
  end

  # Price dates in the holdings payload that are present but cannot be read,
  # which holdings_snapshot_date leaves out.
  def unparseable_holding_price_dates
    holdings = raw_holdings_payload&.dig("holdings") || []
    holdings.filter_map do |holding|
      value = holding["institution_price_as_of"]
      value if value.present? && parse_holding_date(value).nil?
    end
  end

  private
    def parse_holding_date(value)
      return nil if value.blank?
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Plaid guarantees at least one of these.  This validation is a sanity check for that guarantee.
    def has_balance
      return if current_balance.present? || available_balance.present?
      errors.add(:base, :no_balance)
    end
end
