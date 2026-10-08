# What a property or vehicle is worth against the debt secured on it, from one
# viewer's point of view.
#
# Equity counts EVERY loan linked to the asset, not just the loan whose page is
# open: a property with a first and second mortgage has one equity figure, and
# measuring it against one loan would overstate it. The same position is reached
# from either side, so the loan page and the asset page cannot disagree.
#
# A viewer may not be able to see every loan secured on an asset. Equity is then
# withheld (nil) rather than computed over the loans they can see, which would
# quote it too high. Mixed currencies withhold it for the same reason: summing
# across them would need a rate this view has no business choosing.
class Loan::CollateralPosition
  attr_reader :collateral, :viewer

  class << self
    # The position of an asset, or nil when no loan is secured on it or the asset
    # has no value yet.
    def for_collateral(account, viewer:)
      return nil unless account.balance

      position = new(collateral: account, viewer: viewer)
      position.loan_accounts.any? ? position : nil
    end

    # The position of a loan's asset, or nil when it has none, the viewer cannot
    # see it, or no loan in use is secured on it (this loan may be switched off:
    # it is not debt, so its own page would show the whole value as equity).
    def for_loan(loan, viewer:)
      collateral = loan.collateral_account
      return nil unless collateral && viewer && Account.accessible_by(viewer).exists?(id: collateral.id)

      for_collateral(collateral, viewer: viewer)
    end
  end

  def initialize(collateral:, viewer:)
    @collateral = collateral
    @viewer = viewer
  end

  def value
    Money.new(collateral.balance, collateral.currency)
  end

  # The loan accounts secured on the asset that the viewer can see.
  def loan_accounts
    @loan_accounts ||= counted_loan_accounts.accessible_by(viewer).to_a
  end

  # Whether the figures below cover every loan secured on the asset.
  def complete?
    return @complete if defined?(@complete)

    @complete = loan_accounts.size == counted_loan_accounts.count &&
      loan_accounts.all? { |account| account.balance && account.currency == collateral.currency }
  end

  def debt
    return nil unless complete?

    Money.new(loan_accounts.sum(&:balance), collateral.currency)
  end

  def equity
    return nil unless complete?

    value - debt
  end

  private
    # Loans in use. A switched-off or pending-deletion loan is not debt.
    def counted_loan_accounts
      Account.visible.where(
        accountable_type: "Loan",
        accountable_id: Loan.where(collateral_account_id: collateral.id).select(:id)
      )
    end
end
