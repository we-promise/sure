class Rule::ActionExecutor::SetAsTransferOrPayment < Rule::ActionExecutor
  def type
    "select"
  end

  # A confirmed transfer moves the target's balance when it counts transfers,
  # so a user only picks accounts they can write to.
  def options
    target_accounts_for(Current.user).alphabetically.pluck(:name, :id)
  end

  def target_accounts_for(user)
    user ? family.accounts.writable_by(user) : family.accounts
  end

  def claimed_attributes
    [ :transfer ]
  end

  def actionable?(value)
    family.accounts.exists?(id: value)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    target_account = family.accounts.find_by_id(value)
    return 0 unless target_account
    # Transfer::Matcher refuses splits too: a split's amount is carried by its
    # children, and a transfer on either would count the money twice.
    scope = transaction_scope.with_entry.where(entries: { parent_entry_id: nil }).merge(Entry.excluding_split_parents)

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
