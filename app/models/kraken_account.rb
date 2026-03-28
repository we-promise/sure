class KrakenAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :kraken_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :kraken_item_id, allow_nil: true }

  alias_method :current_account, :account

  def ensure_account_provider!(linked_account = nil)
    acct = linked_account || current_account
    return nil unless acct

    AccountProvider
      .find_or_initialize_by(provider_type: "KrakenAccount", provider_id: id)
      .tap do |provider|
        provider.account = acct
        provider.save!
      end
  rescue => e
    Rails.logger.warn("Kraken provider link ensure failed for #{id}: #{e.class} - #{e.message}")
    nil
  end

  def upsert_kraken_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access

    update!(
      current_balance: snapshot[:balance] || snapshot[:current_balance],
      currency: parse_currency(snapshot[:currency]) || "USD",
      name: snapshot[:name],
      account_id: snapshot[:id]&.to_s || account_id,
      account_status: snapshot[:status],
      provider: snapshot[:provider],
      institution_metadata: {
        name: snapshot[:institution_name],
        asset_name: snapshot[:asset_name],
        asset_code: snapshot[:asset_code],
        quote_currency: snapshot[:quote_currency]
      }.compact,
      raw_payload: account_snapshot
    )
  end

  def upsert_kraken_transactions_snapshot!(transactions_snapshot)
    assign_attributes(raw_transactions_payload: transactions_snapshot)
    save!
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for KrakenAccount #{id}, defaulting to USD")
    end
end
