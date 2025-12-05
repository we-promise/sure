class BalanceSheet::SubtypeGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :subtype, :accounts, :account_group

  def initialize(subtype:, accounts:, account_group:)
    @subtype = subtype
    @accounts = accounts
    @account_group = account_group
  end

  def name
    account_group.accountable_type.short_subtype_label_for(subtype) || account_group.name
  end

  def key
    subtype.presence || "other"
  end

  def total
    accounts.sum(&:converted_balance)
  end

  def currency
    account_group.currency
  end
end
