class LunchflowAccount < ApplicationRecord
  include CurrencyNormalizable

  belongs_to :lunchflow_item

  # New association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Helper to get account using account_providers system
  def current_account
    account
  end

  def upsert_lunchflow_snapshot!(account_snapshot)
    # Convert to symbol keys or handle both string and symbol keys
    snapshot = account_snapshot.with_indifferent_access

    # Map Lunchflow field names to our field names
    # Lunchflow API returns: { id, name, institution_name, institution_logo, provider, currency, status }
    update!(
      current_balance: nil, # Balance not provided by accounts endpoint
      currency: parse_currency(snapshot[:currency]) || "USD",
      name: snapshot[:name],
      account_id: snapshot[:id].to_s,
      account_status: snapshot[:status],
      provider: snapshot[:provider],
      institution_metadata: {
        name: snapshot[:institution_name],
        logo: snapshot[:institution_logo]
      }.compact,
      raw_payload: account_snapshot
    )
  end

  def upsert_lunchflow_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for LunchFlow account #{id}, defaulting to USD")
    end
end
