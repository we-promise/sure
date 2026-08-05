class Rule::ActionExecutor::InvertTransactionAmount < Rule::ActionExecutor
  def label
    I18n.t("rules.action_executors.invert_transaction_amount")
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    scope = transaction_scope.with_entry
    unless ignore_attribute_locks
      scope = scope.where.not(Arel.sql("entries.locked_attributes ? 'amount'"))
    end

    modified_entries = scope.filter_map do |transaction|
      invert_amount_once(transaction, ignore_attribute_locks: ignore_attribute_locks)
    end

    schedule_account_recalculations(modified_entries)
    modified_entries.size
  end

  private
    def invert_amount_once(transaction, ignore_attribute_locks:)
      entry = transaction.entry

      # Entry#transaction is the delegated Transaction accessor, so use an
      # explicit class transaction before locking the Entry row.
      Entry.transaction do
        entry.lock!
        transaction.reload

        if entry.amount.zero? || transaction.amount_inversion_corrected_amount == entry.amount
          false
        else
          source_amount = entry.amount
          corrected_amount = entry.amount * -1
          modified = entry.enrich_attribute(
            :amount,
            corrected_amount,
            source: "rule",
            metadata: { rule_id: rule.id, action_type: key },
            ignore_locks: ignore_attribute_locks
          )

          if modified
            transaction.record_amount_inversion!(source_amount:, corrected_amount:)
            entry
          else
            false
          end
        end
      end
    end

    def schedule_account_recalculations(entries)
      entries.group_by(&:account_id).each_value do |account_entries|
        earliest_date = account_entries.filter_map(&:date).min
        # Account sync rematerializes persisted balances; its post-sync hook
        # also reruns transfer matching against the corrected direction.
        account_entries.first.account.sync_later(window_start_date: earliest_date)
      end
    end
end
