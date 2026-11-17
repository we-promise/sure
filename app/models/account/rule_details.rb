# What the account page's "Details" tab lists: each rule that applies to the
# account, its value, and where the value comes from (the subtype, the account
# type, or the user). Answers questions such as "why does this account not
# count in my budget?" without anyone reading code.
#
# Values and sources are symbols/raw values; the view turns them into text.
class Account::RuleDetails
  Row = Data.define(:key, :value, :source)

  attr_reader :account, :date

  def initialize(account, date: account.liquidity_today)
    @account = account
    @date = date
  end

  def rows
    [
      liquidity_row,
      release_row,
      tax_treatment_row,
      budget_row,
      budget_cash_row
    ].compact
  end

  def subtype_label
    account.subtype.present? ? account.long_subtype_label : nil
  end

  private
    # Where a default comes from: the subtype when there is one, else the type.
    def default_source
      account.subtype.present? ? :subtype : :account_type
    end

    def liquidity_row
      Row.new(
        key: :liquidity,
        value: account.effective_liquidity(date),
        source: account.liquidity_manual? ? :user : default_source
      )
    end

    def release_row
      return nil unless account.liquidity == "locked"

      Row.new(key: :release, value: account.next_release_date(date), source: :user)
    end

    # Crypto keeps its tax treatment in a column the user sets; Investment and
    # Depository derive it from the subtype.
    def tax_treatment_row
      return nil if account.tax_treatment.nil?

      source = account.crypto? ? :user : default_source
      Row.new(key: :tax_treatment, value: account.tax_treatment, source: source)
    end

    # Whether the account's transactions count as income and spending.
    def budget_row
      Row.new(key: :counts_in_budget, value: !account.tax_advantaged?, source: :tax_treatment)
    end

    # Whether the balance counts as money for this month's budget ("really
    # free"): only immediately available assets do.
    def budget_cash_row
      return nil unless account.asset?

      Row.new(key: :counts_as_budget_cash, value: account.effective_liquidity(date) == "immediate", source: :liquidity)
    end
end
