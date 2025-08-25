class DirectBank::OpeningBalanceCreator
  def initialize(account, balance_amount)
    @account = account
    @balance_amount = balance_amount.to_d
  end

  def create
    return if @balance_amount.zero?

    opening_balance_date = 30.days.ago.to_date

    @account.transactions.create!(
      date: opening_balance_date,
      amount: @balance_amount,
      name: "Opening Balance",
      pending: false,
      category: opening_balance_category
    )

    @account.update!(balance: @balance_amount)
  end

  private

  def opening_balance_category
    @account.family.categories.find_or_create_by(
      name: "Opening Balance",
      system_category: true
    )
  end
end