class BondLotsController < ApplicationController
  before_action :set_bond_lot, only: %i[show edit update destroy]

  def new
    @account = accessible_accounts.find(params[:account_id])
    return unless require_account_permission!(@account)
    return redirect_back_or_to(account_path(@account), alert: t("bond_lots.not_bond_account")) unless @account.bond?

    @bond_lot = @account.bond.bond_lots.build(
      purchased_on: Date.current,
      term_months: @account.bond.term_months,
      interest_rate: @account.bond.interest_rate,
      subtype: @account.bond.subtype,
      rate_type: @account.bond.rate_type,
      coupon_frequency: @account.bond.coupon_frequency
    )
  end

  def edit
    @account = @bond_lot.account
    return unless require_account_permission!(@account) # rubocop:disable Style/RedundantReturn
  end

  def show
    @account = @bond_lot.account
    return unless require_account_permission!(@account) # rubocop:disable Style/RedundantReturn
  end

  def create
    @account = accessible_accounts.find(params[:account_id])
    return unless require_account_permission!(@account)

    return redirect_back_or_to(account_path(@account), alert: t("bond_lots.not_bond_account")) unless @account.bond?

    @bond_lot = @account.bond.bond_lots.build(bond_lot_params(@account.bond))

    if @bond_lot.valid?
      begin
        ActiveRecord::Base.transaction do
          @bond_lot.save!
          @bond_lot.create_purchase_entry!
        end
      rescue ActiveRecord::RecordInvalid => e
        @bond_lot.errors.add(:base, e.record.errors.full_messages.to_sentence)
        return render :new, status: :unprocessable_entity
      end

      @account.sync_later(window_start_date: @bond_lot.purchased_on)
      redirect_back_or_to account_path(@account), notice: t("bond_lots.create.success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    @account = @bond_lot.account
    return unless require_account_permission!(@account)

    old_purchased_on = @bond_lot.purchased_on

    begin
      ActiveRecord::Base.transaction do
        @bond_lot.update!(bond_lot_params(@bond_lot.bond))
        @bond_lot.update_purchase_entry!
      end
      @bond_lot.account.sync_later(window_start_date: [ old_purchased_on, @bond_lot.purchased_on ].min)
      redirect_back_or_to account_path(@account), notice: t("bond_lots.update.success")
    rescue ActiveRecord::RecordInvalid => e
      @bond_lot.errors.add(:base, e.record.errors.full_messages.to_sentence) if e.record != @bond_lot
      template = request.headers["Turbo-Frame"] == "drawer" ? :show : :edit
      render template, status: :unprocessable_entity
    end
  end

  def destroy
    return unless require_account_permission!(@bond_lot.account)

    account = @bond_lot.account
    sync_start_date = @bond_lot.purchased_on

    entry = @bond_lot.entry

    ActiveRecord::Base.transaction do
      # Entry has_one :bond_lot, dependent: :destroy — destroying entry cascades to lot.
      # Only destroy lot directly when no entry exists.
      if entry
        entry.destroy!
      else
        @bond_lot.destroy!
      end
    end

    account.sync_later(window_start_date: sync_start_date)

    redirect_back_or_to account_path(account), notice: t("bond_lots.destroy.success")
  end

  private
    def set_bond_lot
      @bond_lot = BondLot.joins(bond: :account)
                         .where(accounts: { family_id: Current.family.id })
                         .merge(Account.accessible_by(Current.user))
                         .find(params[:id])
    end

    def bond_lot_params(bond = nil)
      params.require(:bond_lot).permit(
        :purchased_on,
        :issue_date,
        :amount,
        :units,
        :nominal_per_unit,
        :term_months,
        :interest_rate,
        :first_period_rate,
        :inflation_margin,
        :inflation_rate_assumption,
        :cpi_lag_months,
        :auto_fetch_inflation,
        :auto_close_on_maturity,
        :early_redemption_fee,
        :subtype,
        :product_code,
        :rate_type,
        :coupon_frequency
      ).tap do |permitted|
        # Allow tax fields only if bond is not tax-exempt
        if !bond&.tax_exempt_wrapper?
          permitted.merge!(params.require(:bond_lot).permit(:tax_strategy, :tax_rate))
        end
      end
    end
end
