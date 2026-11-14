module CategoriesHelper
  def transfer_category
    Category.new \
      name: I18n.t("categories.virtual.transfer"),
      color: Category::TRANSFER_COLOR,
      lucide_icon: "arrow-right-left"
  end

  def payment_category
    Category.new \
      name: I18n.t("categories.virtual.payment"),
      color: Category::PAYMENT_COLOR,
      lucide_icon: "arrow-right"
  end

  def trade_category
    Category.new \
      name: I18n.t("categories.virtual.trade"),
      color: Category::TRADE_COLOR
  end

  # The outflow's category (or its Transfer/Payment badge when none is set)
  # an inflow leg of a categorizable transfer shows read-only
  # (Transaction#category_set_on_transfer_outflow?), or nil when it shows
  # none. Like the counterpart name in transactions/_transaction, it is
  # hidden when the viewer cannot access the outflow's account.
  def transfer_outflow_category(transaction, accessible_account_ids: @accessible_account_ids)
    return unless transaction.category_set_on_transfer_outflow?

    from_account_id = transaction.transfer.outflow_transaction.entry.account_id
    visible = if accessible_account_ids
      accessible_account_ids.include?(from_account_id)
    else
      Current.user.present? && Current.user.accessible_accounts.exists?(id: from_account_id)
    end
    return unless visible

    display_category_for(transaction.transfer.outflow_transaction)
  end

  # The badge a transaction shows when its category is not editable.
  def read_only_category(transaction)
    transfer_outflow_category(transaction) || (transaction.payment? ? payment_category : transfer_category)
  end

  def family_categories
    [ Category.uncategorized ].concat(Current.family.categories.alphabetically_by_hierarchy)
  end

  # Transactions keep a real, editable category (nil when none is chosen).
  # For funds_movement/cc_payment legs with no category picked, show the
  # Transfer/Payment badge: those kinds are excluded from the Uncategorized
  # bucket. Other kinds (loan_payment, investment_contribution) are counted as
  # Uncategorized, so they keep the Uncategorized badge to match the filter (#2592).
  def display_category_for(transaction)
    return transaction.category if transaction.category

    if Transaction::UNCATEGORIZED_EXCLUDED_KINDS.include?(transaction.kind) && transaction.transfer
      return transaction.transfer.payment? ? payment_category : transfer_category
    end

    Category.uncategorized
  end
end
