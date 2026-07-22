class UI::Account::BalanceReconciliation < ApplicationComponent
  attr_reader :balance, :account

  def initialize(balance:, account:)
    @balance = balance
    @account = account
  end

  def reconciliation_items
    case account.accountable_type
    when "Depository", "OtherAsset", "OtherLiability"
      default_items
    when "CreditCard"
      credit_card_items
    when "Investment"
      investment_items
    when "Loan"
      loan_items
    when "Insurance", "Property", "Vehicle"
      asset_items
    when "Crypto"
      crypto_items
    else
      default_items
    end
  end

  private

    def t_label(key)
      I18n.t("UI.account.balance_reconciliation.labels.#{key}")
    end

    def t_tooltip(key)
      I18n.t("UI.account.balance_reconciliation.tooltips.#{key}")
    end

    def default_items
      items = [
        { label: t_label(:start_balance), value: balance.start_balance_money, tooltip: t_tooltip(:start_balance), style: :start },
        { label: t_label(:net_cash_flow), value: net_cash_flow, tooltip: t_tooltip(:net_cash_flow), style: :flow }
      ]

      if has_adjustments?
        items << { label: t_label(:end_balance), value: end_balance_before_adjustments, tooltip: t_tooltip(:end_balance), style: :subtotal }
        items << { label: t_label(:adjustments), value: total_adjustments, tooltip: t_tooltip(:adjustments), style: :adjustment }
      end

      items << { label: t_label(:final_balance), value: balance.end_balance_money, tooltip: t_tooltip(:final_balance), style: :final }
      items
    end

    def credit_card_items
      items = [
        { label: t_label(:start_balance), value: balance.start_balance_money, tooltip: t_tooltip(:start_balance_credit), style: :start },
        { label: t_label(:charges), value: balance.cash_outflows_money, tooltip: t_tooltip(:charges), style: :flow },
        { label: t_label(:payments), value: balance.cash_inflows_money * -1, tooltip: t_tooltip(:payments), style: :flow }
      ]

      if has_adjustments?
        items << { label: t_label(:end_balance), value: end_balance_before_adjustments, tooltip: t_tooltip(:end_balance), style: :subtotal }
        items << { label: t_label(:adjustments), value: total_adjustments, tooltip: t_tooltip(:adjustments), style: :adjustment }
      end

      items << { label: t_label(:final_balance), value: balance.end_balance_money, tooltip: t_tooltip(:final_balance_credit), style: :final }
      items
    end

    def investment_items
      items = [
        { label: t_label(:start_balance), value: balance.start_balance_money, tooltip: t_tooltip(:start_balance_investment), style: :start }
      ]

      items << { label: t_label(:change_in_brokerage_cash), value: net_cash_flow, tooltip: t_tooltip(:change_in_brokerage_cash), style: :flow }
      items << { label: t_label(:change_in_holdings_trades), value: net_non_cash_flow, tooltip: t_tooltip(:change_in_holdings_trades), style: :flow }
      items << { label: t_label(:change_in_holdings_market), value: balance.net_market_flows_money, tooltip: t_tooltip(:change_in_holdings_market), style: :flow }

      if has_adjustments?
        items << { label: t_label(:end_balance), value: end_balance_before_adjustments, tooltip: t_tooltip(:end_balance_investment), style: :subtotal }
        items << { label: t_label(:adjustments), value: total_adjustments, tooltip: t_tooltip(:adjustments), style: :adjustment }
      end

      items << { label: t_label(:final_balance), value: balance.end_balance_money, tooltip: t_tooltip(:final_balance_investment), style: :final }
      items
    end

    def loan_items
      items = [
        { label: t_label(:start_principal), value: balance.start_balance_money, tooltip: t_tooltip(:start_principal), style: :start },
        { label: t_label(:net_principal_change), value: net_non_cash_flow, tooltip: t_tooltip(:net_principal_change), style: :flow }
      ]

      if has_adjustments?
        items << { label: t_label(:end_principal), value: end_balance_before_adjustments, tooltip: t_tooltip(:end_principal), style: :subtotal }
        items << { label: t_label(:adjustments), value: balance.non_cash_adjustments_money, tooltip: t_tooltip(:adjustments), style: :adjustment }
      end

      items << { label: t_label(:final_principal), value: balance.end_balance_money, tooltip: t_tooltip(:final_principal), style: :final }
      items
    end

    def asset_items
      items = [
        { label: t_label(:start_value), value: balance.start_balance_money, tooltip: t_tooltip(:start_value), style: :start },
        { label: t_label(:net_value_change), value: net_total_flow, tooltip: t_tooltip(:net_value_change), style: :flow }
      ]

      if has_adjustments?
        items << { label: t_label(:end_value), value: end_balance_before_adjustments, tooltip: t_tooltip(:end_value), style: :subtotal }
        items << { label: t_label(:adjustments), value: total_adjustments, tooltip: t_tooltip(:adjustments_asset), style: :adjustment }
      end

      items << { label: t_label(:final_value), value: balance.end_balance_money, tooltip: t_tooltip(:final_value), style: :final }
      items
    end

    def crypto_items
      items = [
        { label: t_label(:start_balance), value: balance.start_balance_money, tooltip: t_tooltip(:start_balance_crypto), style: :start }
      ]

      items << { label: t_label(:buys), value: balance.cash_outflows_money * -1, tooltip: t_tooltip(:buys), style: :flow } if balance.cash_outflows != 0
      items << { label: t_label(:sells), value: balance.cash_inflows_money, tooltip: t_tooltip(:sells), style: :flow } if balance.cash_inflows != 0
      items << { label: t_label(:market_changes), value: balance.net_market_flows_money, tooltip: t_tooltip(:market_changes), style: :flow } if balance.net_market_flows != 0

      if has_adjustments?
        items << { label: t_label(:end_balance), value: end_balance_before_adjustments, tooltip: t_tooltip(:end_balance_crypto), style: :subtotal }
        items << { label: t_label(:adjustments), value: total_adjustments, tooltip: t_tooltip(:adjustments), style: :adjustment }
      end

      items << { label: t_label(:final_balance), value: balance.end_balance_money, tooltip: t_tooltip(:final_balance_crypto), style: :final }
      items
    end

    def net_cash_flow
      balance.cash_inflows_money - balance.cash_outflows_money
    end

    def net_non_cash_flow
      balance.non_cash_inflows_money - balance.non_cash_outflows_money
    end

    def net_total_flow
      net_cash_flow + net_non_cash_flow + balance.net_market_flows_money
    end

    def total_adjustments
      balance.cash_adjustments_money + balance.non_cash_adjustments_money
    end

    def has_adjustments?
      balance.cash_adjustments != 0 || balance.non_cash_adjustments != 0
    end

    def end_balance_before_adjustments
      balance.end_balance_money - total_adjustments
    end
end
