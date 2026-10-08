# A user's retirement plan: the settings behind the FIRE figures.
#
# Per user, not per family: the figures a plan drives are built from the
# accounts its user can see (see #projection), so a family-level plan would
# project a different set of accounts for each member who opened it.
class RetirementPlan < ApplicationRecord
  belongs_to :user

  validates :safe_withdrawal_rate, presence: true,
                                   numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :expected_annual_return, presence: true,
                                     numericality: { greater_than: -1, less_than_or_equal_to: 1 }
  # Blank means "derive it from income and expenses", which is a different
  # answer from an explicit zero.
  validates :savings_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
                           allow_nil: true
  validate :percent_inputs_are_numbers

  # The user's saved plan, or an unsaved one carrying the column defaults.
  # Never writes: opening a page must not create a row.
  def self.for(user)
    find_by(user: user) || new(user: user)
  end

  PERCENT_ATTRIBUTES = %i[safe_withdrawal_rate expected_annual_return savings_rate].freeze

  # The form speaks in percent; the columns hold fractions. Blank stays blank,
  # which for the savings rate means "derive it". Input that is not a number
  # is refused, not read as zero: "abc".to_d is 0, and an explicit 0% savings
  # rate switches off the derived one. The attribute keeps what it held, and
  # the error sits on the field the user typed into.
  PERCENT_ATTRIBUTES.each do |attribute|
    define_method(:"#{attribute}_percent") do
      value = public_send(attribute)
      value && (value * 100)
    end

    define_method(:"#{attribute}_percent=") do |percent|
      non_numeric_percents.delete(attribute)

      if percent.blank?
        public_send(:"#{attribute}=", nil)
      elsif (parsed = BigDecimal(percent.to_s.strip, exception: false))
        public_send(:"#{attribute}=", parsed / 100)
      else
        non_numeric_percents << attribute
      end
    end
  end

  # The account types whose balance is money the user could live off:
  # cash, and what is invested. A property or a vehicle is wealth, but not a
  # portfolio a withdrawal rate can be applied to.
  LIQUID_AND_INVESTMENT_TYPES = %w[Depository Investment Crypto].freeze

  # IncomeStatement counts money moved into an investment account as an
  # expense, which is right for a budget. For a FIRE plan it is saving:
  # counted as spending, it would raise the FI number and lower the derived
  # savings rate at once. Loan payments stay in, because until a loan is paid
  # off they are money the user has to find every month.
  SAVING_KINDS = %w[investment_contribution].freeze

  def projection(as_of:)
    RetirementPlan::Projection.new(
      as_of: as_of,
      annual_expenses: income_statement.median_expense(interval: "month", excluding_kinds: SAVING_KINDS).to_d * 12,
      annual_income: income_statement.median_income(interval: "month").to_d * 12,
      current_assets: assets_as_of(as_of).total,
      safe_withdrawal_rate: safe_withdrawal_rate,
      expected_annual_return: expected_annual_return,
      savings_rate: savings_rate,
      retirement_date: retirement_date
    )
  end

  # Accounts left out of the asset total for want of an exchange rate on the
  # reference date. The card says so rather than showing a quietly low figure.
  def unconverted_account_count(as_of:)
    assets_as_of(as_of).unconverted_count
  end

  private
    def non_numeric_percents
      @non_numeric_percents ||= Set.new
    end

    def percent_inputs_are_numbers
      non_numeric_percents.each { |attribute| errors.add(:"#{attribute}_percent", :not_a_number) }
    end

    AssetTotal = Data.define(:total, :unconverted_count)

    # The same scope InvestmentStatement#investment_accounts uses:
    # what this user counts in their own finances. Family-wide would show a
    # member the combined balance of accounts never shared with them.
    def finance_accounts
      user.family.accounts.visible.included_in_reports.included_in_finances_for(user)
    end

    # Account scope passed explicitly, as Goal#median_monthly_expense does, so
    # the figures are this plan's user's whoever happens to be Current.
    def income_statement
      @income_statement ||= IncomeStatement.new(user.family, user: user, accounts: finance_accounts)
    end

    def assets_as_of(as_of)
      @assets_as_of ||= {}
      @assets_as_of[as_of] ||= asset_total(as_of, finance_accounts)
    end

    def asset_total(as_of, accounts)
      currency = user.family.currency
      total = BigDecimal("0")
      unconverted = 0

      latest_balances(as_of, accounts).each do |row|
        total += Money.new(row.balance, row.currency).exchange_to(currency, date: as_of).amount
      rescue Money::ConversionError
        unconverted += 1
      end

      AssetTotal.new(total: total, unconverted_count: unconverted)
    end

    # Each account's latest balance on or before the reference date, in the
    # account's own currency.
    def latest_balances(as_of, accounts)
      # By id rather than `merge`: the finance scope is DISTINCT, which cannot
      # sit in front of DISTINCT ON.
      Balance
        .joins(:account)
        .where(account_id: accounts.where(accountable_type: LIQUID_AND_INVESTMENT_TYPES).select(:id))
        .where("balances.date <= ?", as_of)
        .where("balances.currency = accounts.currency")
        .select("DISTINCT ON (balances.account_id) balances.account_id, balances.balance, balances.currency")
        .order("balances.account_id, balances.date DESC")
    end
end
