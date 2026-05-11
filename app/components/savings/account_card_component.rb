class Savings::AccountCardComponent < ApplicationComponent
  def initialize(account:, goals_count: 0)
    @account = account
    @goals_count = goals_count
  end

  attr_reader :account, :goals_count

  def initial
    account.name.to_s.strip.first&.upcase || "?"
  end

  def subtype_label
    (account.subtype || "savings").to_s.titleize
  end

  def funds_label
    I18n.t("savings_goals.index.account_card.funds", count: goals_count)
  end
end
