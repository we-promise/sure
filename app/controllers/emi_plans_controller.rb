class EmiPlansController < ApplicationController
  before_action :set_entry
  before_action :require_emi_write_permission!, only: %i[create destroy]

  def new
    unless @entry.transaction? && @entry.transaction.emi_convertible?
      redirect_back_or_to transactions_path, alert: t("emi_plans.new.not_convertible")
      return
    end

    @default_start_date = @entry.date.next_month
  end

  def create
    unless @entry.transaction? && @entry.transaction.emi_convertible?
      redirect_back_or_to transactions_path, alert: t("emi_plans.new.not_convertible")
      return
    end

    plan = EmiPlan.build!(
      entry: @entry,
      interest_rate: emi_plan_params[:interest_rate].presence || 0,
      tenure_months: emi_plan_params[:tenure_months],
      processing_fee: emi_plan_params[:processing_fee].presence || 0,
      start_date: emi_plan_params[:start_date].presence
    )

    @entry.sync_account_later

    redirect_back_or_to transactions_path, notice: t("emi_plans.create.success", count: plan.tenure_months)
  rescue ActiveRecord::RecordInvalid => e
    # e.message is "Validation failed: <full_messages>" -- the "Validation
    # failed:" prefix is a hard-coded Rails string, not localized. The
    # individual field messages (e.g. tenure/interest_rate bounds) already
    # come from Rails' own i18n-backed error messages, so join those
    # directly instead of using the English-prefixed exception message.
    #
    # Falls back to the localized not_convertible message when there are no
    # field errors to join: EmiPlan.build!'s locked eligibility recheck
    # raises RecordInvalid.new(entry) with only a message string, never
    # actually added to entry.errors, so full_messages is empty there and
    # to_sentence would otherwise redirect with a blank alert.
    alert = e.record.errors.full_messages.to_sentence.presence || t("emi_plans.new.not_convertible")
    redirect_back_or_to transactions_path, alert: alert
  rescue ActiveRecord::RecordNotUnique
    # EmiPlan.build! locks entry and re-checks eligibility under that lock,
    # so this shouldn't normally fire for a same-entry double-submit
    # anymore -- kept as a defense-in-depth backstop for the unique index
    # on emi_plans.entry_id in case any other path ever calls build!
    # without going through this controller's locking.
    redirect_back_or_to transactions_path, alert: t("emi_plans.new.not_convertible")
  end

  def show
    resolve_to_parent!

    unless @entry.emi_purchase?
      redirect_to transactions_path, alert: t("emi_plans.show.not_emi")
      return
    end

    @plan = @entry.originated_emi_plan
  end

  def destroy
    resolve_to_parent!

    unless @entry.emi_purchase? && @entry.originated_emi_plan.active?
      redirect_to transactions_path, alert: t("emi_plans.show.not_emi")
      return
    end

    @entry.originated_emi_plan.foreclose!
    @entry.sync_account_later

    redirect_to transactions_path, notice: t("emi_plans.destroy.success")
  end

  private

    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    def require_emi_write_permission!
      require_account_permission!(@entry.account, redirect_path: transactions_path)
    end

    def resolve_to_parent!
      return unless @entry.emi_installment?
      plan = EmiPlan.find_by(id: @entry.emi_plan_id)
      @entry = plan.entry if plan.present?
    end

    def emi_plan_params
      params.require(:emi_plan).permit(:interest_rate, :tenure_months, :processing_fee, :start_date)
    end
end
