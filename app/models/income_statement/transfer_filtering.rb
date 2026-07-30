module IncomeStatement::TransferFiltering
  private
    def transfer_filter_sql(transaction_alias)
      Transaction.cash_flow_transfer_sql(
        transaction_alias,
        include_investment_contributions: @include_investment_contributions
      )
    end
end
