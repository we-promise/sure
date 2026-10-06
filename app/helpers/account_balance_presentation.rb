# Shared presentation rule for individual account balances. Keep this separate
# from ActionView so components can use it before render as well as helpers.
module AccountBalancePresentation
  module_function

  # Negates balances only for individual liability accounts when the current
  # user opts in. Aggregates and canonical account values retain their signs.
  def balance_for_account_display(account, money = account.balance_money)
    return money unless account.liability? && Current.user&.negative_liability_balances?

    money * -1
  end
end
