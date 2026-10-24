# One second-level group inside a BalanceSheet::AccountGroup, e.g. all
# depository accounts at one institution. See AccountGrouping.
class BalanceSheet::AccountSubgroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :key, :name, :accounts

  def initialize(key:, name:, accounts:, account_group:)
    @key = key
    @name = name
    @accounts = accounts
    @account_group = account_group
  end

  def total
    BalanceSheet::ClassificationGroup.counted_accounts(accounts).sum(&:converted_balance)
  end

  # Share of the whole classification (all assets or all debts), in percent,
  # on the same basis as the account group and account rows next to it.
  def weight
    classification_total = account_group.classification_total
    return 0 if classification_total.zero?

    total / classification_total.to_d * 100
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  def currency
    account_group.currency
  end

  def color
    account_group.color
  end

  # Keys can be free text in any script, so hash them for a safe, unique id.
  def token
    Digest::SHA256.hexdigest(key.to_s).first(12)
  end

  def dom_id(tab: nil, mobile: false)
    "#{account_group.dom_id(tab: tab, mobile: mobile)}_#{token}"
  end

  private
    attr_reader :account_group
end
