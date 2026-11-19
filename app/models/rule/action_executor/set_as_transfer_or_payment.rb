class Rule::ActionExecutor::SetAsTransferOrPayment < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    target_accounts.alphabetically.pluck(:name, :id)
  end

  def options_cache_key
    rule.restricted? ? [ rule.user_id ] : []
  end

  # A saved target the editor can't pick keeps a label, without the name of
  # an account they can't write.
  def option_for(value)
    [ I18n.t("rule.actions.set_as_transfer_or_payment.not_accessible"), value ] if family.accounts.exists?(id: value)
  end

  def claimed_attributes
    [ :transfer ]
  end

  def actionable?(value)
    target_accounts.exists?(id: value)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    target_account = target_accounts.find_by(id: value)
    return 0 unless target_account
    scope = transaction_scope.with_entry
    # Checked once per run, not per transaction.
    reconcile_pledges = target_account.linked_to_goal?

    count_modified_resources(scope) do |txn|
      entry = txn.entry
      unless txn.transfer?
        transfer = build_transfer(target_account, entry)
        Transfer.transaction do
          transfer.save!
          transfer.confirm!
        end

        transfer.sync_account_later
        # An outflow's new counterpart is a deposit on the target account.
        GoalPledge::Reconciler.run_after_commit(transfer.inflow_transaction.entry) if reconcile_pledges && entry.amount.positive?
      end
    end
  end

  private
    # The action writes an entry into the target, so it must be an account
    # the rule's owner can write (the whole family for an unrestricted rule).
    def target_accounts
      rule.restricted? ? family.accounts.writable_by(rule.user) : family.accounts
    end

    def build_transfer(target_account, entry)
      missing_transaction = Transaction.new(
        entry: target_account.entries.build(
          amount: entry.amount * -1,
          currency: entry.currency,
          date: entry.date,
          name: "#{target_account.liability? ? "Payment" : "Transfer"} #{entry.amount.negative? ? "to #{target_account.name}" : "from #{entry.account.name}"}",
          user_modified: true,
        )
      )

      transfer = Transfer.find_or_initialize_by(
        inflow_transaction: entry.amount.positive? ? missing_transaction : entry.transaction,
        outflow_transaction: entry.amount.positive? ? entry.transaction : missing_transaction
      )
      transfer.status = "confirmed"
      transfer
    end
end
