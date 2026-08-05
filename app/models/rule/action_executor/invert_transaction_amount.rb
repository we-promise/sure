class Rule::ActionExecutor::InvertTransactionAmount < Rule::ActionExecutor
  def label
    I18n.t("rules.action_executors.invert_transaction_amount")
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    scope = invertible_scope(transaction_scope)
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
    # Flipping a sign is only self-contained for a standalone transaction. Three
    # shapes carry a cross-record sum invariant that nothing re-checks when an
    # Entry amount changes, so inverting one leaves persistent corruption:
    #
    # - Transfer legs. Transfer validates that its legs have opposite signs and
    #   sum to zero, but no callback re-validates the transfer when an entry is
    #   written, so the row survives in an invalid state. It cannot self-heal,
    #   because auto transfer matching only considers transactions that are not
    #   already attached to a transfer.
    # - Transfer fees. These hang off the transfer through transfer_id rather
    #   than either leg association, and they are ordinary standard-kind rows,
    #   so nothing else filters them out. Transfer#derived_source_fee_amount
    #   sums them by account, so flipping one turns a reported fee negative and
    #   moves the account balance. No validation covers fees, so the transfer
    #   still reports itself as valid.
    # - Split children. Entry#split! enforces sum(children) == parent.amount
    #   only at split time, and the excluded parent means balances derive from
    #   the children, so flipping one child silently moves the account balance.
    #
    # All three are skipped rather than corrected. They are reported as blocked
    # in the rule run counts, the same treatment a locked amount gets.
    def invertible_scope(transaction_scope)
      transaction_scope
        .with_entry
        .preload(entry: :account)
        .where(transactions: { transfer_id: nil })
        .where(entries: { parent_entry_id: nil })
        .where.missing(:transfer_as_inflow, :transfer_as_outflow)
    end

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
        # Account sync rematerializes persisted balances. Its post-sync hook
        # also reruns transfer matching, which can now pair a corrected
        # transaction that previously had the wrong sign to match against.
        account_entries.first.account.sync_later(window_start_date: earliest_date)
      end
    end
end
