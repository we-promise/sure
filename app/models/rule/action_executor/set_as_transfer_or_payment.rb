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

  # Keeps showing a target another member saved, which this user can't pick.
  def option_for(value)
    family.accounts.where(id: value).pick(:name, :id) if UuidFormat.valid?(value)
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
    # Like Transfer::Matcher, skip split children and excluded entries (split
    # parents are always excluded): a transfer on a split would count its
    # amount twice, and an excluded entry's counterpart would not be excluded.
    # A transfer needs two accounts, so the target's own entries are skipped.
    scope = transaction_scope.with_entry
      .where(entries: { parent_entry_id: nil })
      .where(entries: { excluded: [ false, nil ] })
      .where.not(entries: { account_id: target_account.id })

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
