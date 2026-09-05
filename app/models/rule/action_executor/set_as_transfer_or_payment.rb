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
      # Converting a purchase to EMI and converting it to a transfer are
      # mutually exclusive operations. Skip silently here (same as the
      # existing txn.transfer? skip below) rather than let it reach
      # Transaction#update! and raise past
      # cannot_change_kind_of_active_emi_entry mid-batch, which would halt
      # every other transaction in this rule run.
      #
      # emi_fee entries are only linked to their plan via
      # EmiPlan#processing_fee_entry (not emi_plan_id like installments), so
      # Transaction#cannot_change_kind_of_active_emi_entry can't catch this
      # path -- skip them explicitly via emi_linked? (covers purchase,
      # installment, and fee) rather than relying on that guard.
      next false if entry.emi_linked?

      unless txn.transfer?
        transfer = build_transfer(target_account, entry)
        Transfer.transaction do
          transfer.save!

          # Use DESTINATION (inflow) account for kind, matching Transfer::Creator logic
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
