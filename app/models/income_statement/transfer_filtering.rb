module IncomeStatement::TransferFiltering
  private
    def transfer_filter_sql(transaction_alias)
      if @include_investment_contributions
        Transaction.cash_flow_transfer_sql(transaction_alias)
      else
        Transaction.unmatched_transfer_sql(transaction_alias)
      end
    end
end
