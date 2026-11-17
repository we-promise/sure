class Rule::ActionExecutor::SetAsTransferOrPayment < Rule::ActionExecutor
  def type
    "select"
  end

  # The form also leaves out accounts the member editing it can't write: the
  # save restricts the rule to them (Rule#restrict_to_editor).
  def options
    editor = Current.user unless Current.user.nil? || Current.user.admin?
    rule.accounts_permitted_to([ *rule.restricting_users, editor ].compact.uniq, :write).alphabetically.pluck(:name, :id)
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

    count_modified_resources(scope) do |txn|
      entry = txn.entry
      unless txn.transfer?
        transfer = build_transfer(target_account, entry)
        Transfer.transaction do
          transfer.save!
          transfer.confirm!
        end

        transfer.sync_account_later
      end
    end
  end

  private
    # The action writes an entry into the target, so it must be an account
    # every user bounding the rule can write.
    def target_accounts
      rule.accounts_permitted_to(rule.restricting_users, :write)
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
