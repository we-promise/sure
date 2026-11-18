# Brings the stored kinds of transfers into bank accounts in line with
# Transfer#kind_for_leg after a transfer from available money into a locked or
# long-term account started counting as saving (investment_contribution), and
# again after an account's availability changes.
# Kinds are stored per transaction, so transfers booked before that rule keep
# funds_movement until this runs; the same movement would otherwise be
# classified differently before and after the upgrade.
#
# Same guarantees as Transfer::InvestmentKindReconciler (only transfer kinds,
# no excluded entries or locked kinds, idempotent). Unlike it, only confirmed
# transfers are touched (a pending suggestion must not move budgets) and the
# Investment Contributions category follows the kind, as on confirm!. Transfers into investment and crypto accounts, including those whose
# source is now a locked deposit, are that reconciler's job.
class Transfer::SavingsKindReconciler < Transfer::InvestmentKindReconciler
  private
    def transfers
      scope
        .joins(inflow_transaction: { entry: :account })
        .where(status: "confirmed")
        # Every bank account, not only bound ones: after an account is marked
        # available, its earlier transfers have to lose the saving kind too.
        .where(accounts: { accountable_type: "Depository" })
        .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
    end

    def repair!(transaction, kind)
      super

      category = contributions_category(transaction.entry.account.family_id)
      return if category.nil?

      if kind == "investment_contribution" && transaction.category_id.nil?
        transaction.update_columns(category_id: category.id)
      elsif kind != "investment_contribution" && transaction.category_id == category.id
        transaction.update_columns(category_id: nil)
      end
    end

    def contributions_category(family_id)
      @contributions_categories ||= {}
      return @contributions_categories[family_id] if @contributions_categories.key?(family_id)

      @contributions_categories[family_id] = Family.find(family_id).investment_contributions_category
    end
end
