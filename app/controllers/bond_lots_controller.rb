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
    nil unless require_account_permission!(@account)
  end

  def show
    @account = @bond_lot.account
    nil unless require_account_permission!(@account)
  end

  def create
    @account = accessible_accounts.find(params[:account_id])
    return unless require_account_permission!(@account)

    return render :new, status: :unprocessable_entity unless @account.bond?

    @bond_lot = @account.bond.bond_lots.build(bond_lot_params)

    if @bond_lot.valid?
      ActiveRecord::Base.transaction do
        @bond_lot.save!
        @bond_lot.update!(entry: create_purchase_entry!(@account, @bond_lot))
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
        @bond_lot.update!(bond_lot_params)
        update_purchase_entry!(@bond_lot)
      end
      @bond_lot.account.sync_later(window_start_date: [ old_purchased_on, @bond_lot.purchased_on ].min)
      redirect_back_or_to account_path(@account), notice: t("bond_lots.update.success")
    rescue ActiveRecord::RecordInvalid
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    return unless require_account_permission!(@bond_lot.account)

    account = @bond_lot.account
    sync_start_date = @bond_lot.purchased_on

    entry = @bond_lot.entry

    ActiveRecord::Base.transaction do
      @bond_lot.destroy!
      entry&.destroy!
    end

    account.sync_later(window_start_date: sync_start_date)

    redirect_back_or_to account_path(account), notice: t("bond_lots.destroy.success")
  end

  private
    def set_bond_lot
      @bond_lot = BondLot.joins(bond: :account)
                         .merge(Account.accessible_by(Current.user))
                         .find(params[:id])
    end

    def bond_lot_params
      params.require(:bond_lot).permit(
        :purchased_on,
        :issue_date,
        :amount,
        :units,
        :nominal_per_unit,
        :term_months,
        :maturity_date,
        :interest_rate,
        :first_period_rate,
        :inflation_margin,
        :inflation_rate_assumption,
        :cpi_lag_months,
        :auto_fetch_inflation,
        :auto_close_on_maturity,
        :tax_strategy,
        :tax_rate,
        :early_redemption_fee,
        :subtype,
        :rate_type,
        :coupon_frequency
      )
    end

    def update_purchase_entry!(bond_lot)
      return unless bond_lot.entry

      subtype_label = Bond.long_subtype_label_for(bond_lot.subtype) || Bond.display_name.singularize
      bond_lot.entry.update!(
        date: bond_lot.purchased_on,
        name: t("bond_lots.activity.purchase_name", subtype: subtype_label),
        amount: bond_lot.amount,
        entryable_attributes: {
          id: bond_lot.entry.entryable_id,
          extra: bond_lot.entry.entryable.extra.merge(
            "bond_subtype" => bond_lot.subtype,
            "bond_term_months" => bond_lot.term_months,
            "bond_interest_rate" => bond_lot.interest_rate
          )
        }
      )
    end

    def create_purchase_entry!(account, bond_lot)
      subtype_label = Bond.long_subtype_label_for(bond_lot.subtype) || Bond.display_name.singularize

      entry = account.entries.create!(
        date: bond_lot.purchased_on,
        name: t("bond_lots.activity.purchase_name", subtype: subtype_label),
        amount: bond_lot.amount,
        currency: account.currency,
        entryable: Transaction.new(
          kind: :funds_movement,
          extra: {
            "bond_lot_id" => bond_lot.id,
            "bond_subtype" => bond_lot.subtype,
            "bond_term_months" => bond_lot.term_months,
            "bond_interest_rate" => bond_lot.interest_rate
          }
        )
      )

      entry.lock_saved_attributes!
      entry.mark_user_modified!
      entry
    end
end
