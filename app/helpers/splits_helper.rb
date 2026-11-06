module SplitsHelper
  # Merchant picker value for a split row that has no merchant of its own; blank means the parent's.
  NO_MERCHANT = "none".freeze

  def split_row_no_merchant_option
    { label: t("splits.new.without_merchant"), value: NO_MERCHANT }
  end

  # The value a split row's merchant picker starts with: blank while the row follows the
  # parent's merchant, otherwise the row's own merchant or NO_MERCHANT.
  def split_row_merchant_id(child, parent_merchant_id:)
    transaction = child.entryable
    return if transaction.follows_parent_merchant?(parent_merchant_id)

    transaction.merchant_id || NO_MERCHANT
  end
end
