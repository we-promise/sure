class IbkrAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include IbkrAccount::DataHelpers

  if encryption_ready?
    encrypts :raw_holdings_payload
    encrypts :raw_activities_payload
    encrypts :raw_cash_report_payload
    encrypts :raw_equity_summary_payload
  end

  belongs_to :ibkr_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :ibkr_account_id, uniqueness: { scope: :ibkr_item_id, allow_nil: true }

  def current_account
    account || linked_account
  end

  def ensure_account_provider!(account = nil)
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "IbkrAccount", provider_id: id)
      .tap do |record|
        record.account = acct
        record.save!
      end

    reload_account_provider
    provider
  rescue => e
    Rails.logger.warn("IbkrAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}")
    nil
  end

  def upsert_from_ibkr_statement!(account_data)
    data = account_data.with_indifferent_access

    update!(
      ibkr_account_id: data[:ibkr_account_id],
      name: data[:name],
      currency: parse_currency(data[:currency]) || "USD",
      current_balance: data[:current_balance],
      cash_balance: data[:cash_balance],
      institution_metadata: {
        provider_name: "Interactive Brokers",
        statement_from_date: data.dig(:statement, :from_date),
        statement_to_date: data.dig(:statement, :to_date)
      }.compact,
      report_date: data[:report_date],
      raw_holdings_payload: data[:open_positions] || [],
      raw_activities_payload: {
        trades: data[:trades] || [],
        cash_transactions: data[:cash_transactions] || []
      },
      raw_cash_report_payload: data[:cash_report] || [],
      raw_equity_summary_payload: data[:equity_summary_in_base] || [],
      last_holdings_sync: Time.current,
      last_activities_sync: Time.current
    )
  end

  def ibkr_provider
    ibkr_item.ibkr_provider
  end
end
