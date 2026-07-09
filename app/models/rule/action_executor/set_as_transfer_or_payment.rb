class Rule::ActionExecutor::SetAsTransferOrPayment < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.accounts.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    target_account = family.accounts.find_by_id(value)
    return 0 unless target_account
    scope = transaction_scope.with_entry

    count_modified_resources(scope) do |txn|
      entry = txn.entry
      existing_transfer = txn.transfer

      if existing_transfer&.pending?
        if counterpart_account(existing_transfer, txn)&.id == target_account.id
          # The auto-matcher already proposed the pair this rule wants; confirm it
          # instead of creating a duplicate counterpart transaction.
          confirm_transfer!(existing_transfer)
          next true
        else
          # Rules take priority over unconfirmed auto-match proposals (issue #2596).
          # Rejecting (not just destroying) prevents the auto-matcher from
          # re-proposing the same pair on the next sync.
          existing_transfer.reject!
          txn.reload
        end
      end

      unless txn.transfer?
        transfer = build_transfer(target_account, entry)
        Transfer.transaction do
          transfer.save!
          apply_transfer_kinds(transfer)
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

    def counterpart_account(transfer, txn)
      counterpart = if transfer.inflow_transaction_id == txn.id
        transfer.outflow_transaction
      else
        transfer.inflow_transaction
      end

      counterpart&.entry&.account
    end

    def confirm_transfer!(transfer)
      Transfer.transaction do
        transfer.confirm!
        apply_transfer_kinds(transfer)
      end

      transfer.sync_account_later
    end

    # Use DESTINATION (inflow) account for kind, matching Transfer::Creator logic
    def apply_transfer_kinds(transfer)
      destination_account = transfer.inflow_transaction.entry.account
      outflow_kind = Transfer.kind_for_account(destination_account)
      outflow_attrs = { kind: outflow_kind }

      if outflow_kind == "investment_contribution"
        category = destination_account.family.investment_contributions_category
        outflow_attrs[:category] = category if category.present? && transfer.outflow_transaction.category_id.blank?
      end

      transfer.outflow_transaction.update!(outflow_attrs)
      transfer.inflow_transaction.update!(kind: "funds_movement")
    end
end
