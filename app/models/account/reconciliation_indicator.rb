class Account::ReconciliationIndicator
  class << self
    def for_accounts(accounts)
      account_list = accounts.to_a
      return {} if account_list.empty?

      account_ids = account_list.map(&:id)
      manual_reconciliation_available = Entry.connection.column_exists?(:entries, :reconciled_status)
      manual_account_ids = if manual_reconciliation_available
        Account.manual.where(id: account_ids).pluck(:id).to_set
      else
        Set.new
      end
      statement_account_ids = account_ids - manual_account_ids.to_a
      statements_by_account = latest_statements_by_account(statement_account_ids)
      transaction_counts = Entry.where(account_id: account_ids, entryable_type: "Transaction", excluded: false).group(:account_id).count
      statement_unreconciled_entries = Entry.where(account_id: statement_account_ids, entryable_type: "Transaction", excluded: false, reconciled_at: nil)
      statement_unreconciled_counts = statement_unreconciled_entries.group(:account_id).count
      statement_unreconciled_dates = statement_unreconciled_entries.pluck(:account_id, :date).group_by(&:first).transform_values { |entries| entries.map(&:last) }
      manual_unreconciled_counts = if manual_reconciliation_available
        Entry.where(account_id: manual_account_ids, entryable_type: "Transaction", excluded: false)
          .where.not(reconciled_status: "reconciled")
          .group(:account_id)
          .count
      else
        {}
      end
      balances_by_key = balances_for(statements_by_account.values)

      account_list.to_h do |account|
        if manual_account_ids.include?(account.id)
          all_transactions_reconciled = transaction_counts[account.id].to_i.positive? && manual_unreconciled_counts[account.id].to_i.zero?
          status = all_transactions_reconciled ? :matched : (:needs_attention if transaction_counts[account.id].to_i.positive?)
          next [ account.id, status ]
        end

        statement = statements_by_account[account.id]
        statement_status = statement&.reconciliation_status(
          balance_lookup: ->(date, currency) { balances_by_key[[ account.id, date, currency ]] }
        )
        all_transactions_reconciled = transaction_counts[account.id].to_i.positive? && statement_unreconciled_counts[account.id].to_i.zero?
        newer_unreconciled_transactions = statement&.period_end_on.present? &&
          statement_unreconciled_dates.fetch(account.id, []).any? { |date| date > statement.period_end_on }

        status = if statement_status == "mismatched"
          :needs_attention
        elsif statement_status == "matched" && !newer_unreconciled_transactions
          :matched
        elsif all_transactions_reconciled
          :matched
        elsif statement.present? || transaction_counts[account.id].to_i.positive?
          :needs_attention
        end

        [ account.id, status ]
      end
    end

    private
      def latest_statements_by_account(account_ids)
        AccountStatement.where(account_id: account_ids).order(account_id: :asc, created_at: :desc).to_a
          .group_by(&:account_id)
          .transform_values(&:first)
      end

      def balances_for(statements)
        return {} if statements.empty?

        account_ids = statements.map(&:account_id)
        dates = statements.flat_map { |statement| [ statement.period_start_on, statement.period_end_on ] }.compact.uniq
        currencies = statements.map(&:statement_currency).compact.uniq

        Balance.where(account_id: account_ids, date: dates, currency: currencies).index_by do |balance|
          [ balance.account_id, balance.date, balance.currency ]
        end
      end
  end
end
