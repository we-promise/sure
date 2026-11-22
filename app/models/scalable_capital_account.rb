class ScalableCapitalAccount < ApplicationRecord
  belongs_to :scalable_capital_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  enum :kind, { brokerage: "brokerage", cash: "cash", savings: "savings" }

  def create_linked_account!(balance:, cash_balance:)
    type, subtype = case kind
    when "brokerage" then [ "Investment", "brokerage" ]
    when "cash" then [ "Depository", "cash" ]
    when "savings" then [ "Depository", "savings" ]
    end
    account = Account.create!(
      family: scalable_capital_item.family,
      owner: scalable_capital_item.owner,
      name: I18n.t("scalable_capital_items.accounts.#{kind}"),
      currency: "EUR",
      balance: balance,
      cash_balance: cash_balance,
      accountable_type: type,
      accountable_attributes: { subtype: subtype }
    )
    create_account_provider!(account: account)
    account.auto_share_with_family! if account.family.share_all_by_default?
    account
  end
end
