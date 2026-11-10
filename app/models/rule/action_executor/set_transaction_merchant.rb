class Rule::ActionExecutor::SetTransactionMerchant < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.assignable_merchants_for(Current.user).alphabetically.pluck(:name, :id)
  end

  # A saved merchant outside the current user's options stays selected and is
  # marked instead of the form silently switching to another merchant. Its
  # name is only shown while the family still has a record of the unlink: a
  # merchant on accounts the user can't see, another family's merchant and an
  # unknown id all get a label without a name.
  def option_for(value)
    return if value.blank?

    label = if assignable_merchant(value)
      I18n.t("rule.actions.set_transaction_merchant.not_accessible")
    elsif (unlinked = FamilyMerchantAssociation.find_by(family: family, merchant_id: value)&.merchant)
      I18n.t("rule.actions.set_transaction_merchant.unassigned", name: unlinked.name)
    else
      I18n.t("rule.actions.set_transaction_merchant.unavailable")
    end
    [ label, value ]
  end

  def claimed_attributes
    [ :merchant_id ]
  end

  def actionable?(value)
    assignable_merchant(value).present?
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    merchant = assignable_merchant(value)
    return 0 unless merchant

    scope = transaction_scope.excluding_installment_plan_purchases
    unless ignore_attribute_locks
      scope = scope.enrichable(:merchant_id)
    end

    count_modified_resources(scope) do |txn|
      # enrich_attribute returns true if the transaction was actually modified, false otherwise
      txn.enrich_attribute(
        :merchant_id,
        merchant.id,
        source: "rule",
        ignore_locks: ignore_attribute_locks
      )
    end
  end

  private
    # Rules run in the background without a user, so this checks the whole
    # family: one of its own merchants, or a provider merchant that is still on
    # one of its transactions.
    def assignable_merchant(value)
      return unless UuidFormat.valid?(value)

      family.merchants.find_by(id: value) ||
        (ProviderMerchant.find_by(id: value) if family.transactions.exists?(merchant_id: value))
    end
end
