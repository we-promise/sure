# Splits an investment account's value into principal (net money put in) and
# earnings (everything else), from the account's AccountContribution records.
class Account::PrincipalSummary
  attr_reader :account

  def initialize(account)
    @account = account
  end

  def available?
    contributions.any?
  end

  def principal
    Money.new(principal_on(Date.current), currency)
  end

  def earnings
    account.balance_money - principal
  end

  # Earnings as a share of principal; nil when there is no principal to compare.
  def return_percent
    return nil unless principal.amount.positive?

    (earnings.amount / principal.amount * 100).round(1)
  end

  def total_in
    Money.new(contributions.select { |c| c.amount.positive? }.sum(&:amount), currency)
  end

  def total_out
    Money.new(contributions.select { |c| c.amount.negative? }.sum(&:amount).abs, currency)
  end

  def estimated?
    contributions.any?(&:estimated?)
  end

  def principal_on(date)
    contributions.take_while { |c| c.date <= date }.sum(&:principal_value)
  end

  # One point per date in `dates`, for drawing principal under the balance line.
  def series_values(dates)
    running = 0
    index = 0
    dates.sort.map do |date|
      while index < contributions.size && contributions[index].date <= date
        running += contributions[index].principal_value
        index += 1
      end
      { date: date, value: running.to_f }
    end
  end

  private
    def currency
      account.currency
    end

    def contributions
      @contributions ||= account.account_contributions.where(currency: currency).chronological.to_a
    end
end
