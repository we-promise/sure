class TinkoffInvestAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include TinkoffInvestAccount::DataHelpers

  SUBTYPE_MAP = {
    "ACCOUNT_TYPE_TINKOFF" => "brokerage",
    "ORDINARY" => "brokerage",
    "ACCOUNT_TYPE_TINKOFF_IIS" => "brokerage",
    "IIS" => "brokerage",
    "ACCOUNT_TYPE_INVEST_FUND" => "mutual_fund",
    "INVEST_FUND" => "mutual_fund",
    "ACCOUNT_TYPE_INVEST_BOX" => "other",
    "INVEST_BOX" => "other"
  }.freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_portfolio_payload
    encrypts :raw_operations_payload
  end

  belongs_to :tinkoff_invest_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :tinkoff_invest_account_id, uniqueness: { scope: :tinkoff_invest_item_id, allow_nil: true }

  def current_account
    account || linked_account
  end

  def accountable_subtype
    SUBTYPE_MAP.fetch(account_type.to_s.strip.upcase, "brokerage")
  end

  def ensure_account_provider!(account = nil)
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "TinkoffInvestAccount", provider_id: id)
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
      message: "TinkoffInvestAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "tinkoff_invest",
      family: tinkoff_invest_item.family,
      provider_key: "tinkoff_invest"
    )
    nil
  end
end
