# Turns a manual card purchase into a Bills installment series, and edits the
# terms while nothing has been matched to that series yet. The dialog only
# collects the issuer's terms; the schedule and the purchase hand-over belong
# to RecurringTransaction::InstallmentPlan.
class InstallmentPlansController < ApplicationController
  include RecurringFeatureGuardable

  before_action :ensure_recurring_enabled
  before_action :set_entry, only: %i[new create]
  before_action :set_plan, only: %i[edit update]
  before_action :set_preview_parent, only: :preview
  before_action :ensure_plan_terms_editable, only: %i[edit update]

  def new
    unless eligible?
      return redirect_to transaction_path(@entry), alert: t("installment_plans.not_available")
    end

    assign_form_values(
      interest_rate: 0,
      term_months: 12,
      interest_category_id: default_interest_category_id
    )
    prepare_form(editing: false)
  end

  def create
    @plan = build_plan

    if @plan.persisted? && @plan.errors.none?
      redirect_after_save(t(".success"))
    else
      @plan_errors = @plan.errors.full_messages
      assign_form_values(
        interest_rate: plan_params[:interest_rate],
        term_months: plan_params[:term_months],
        first_due_on: first_due_on || @entry.date.next_month,
        interest_category_id: plan_params[:interest_category_id]
      )
      prepare_form(editing: false)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @entry = @plan.financed_source_entry
    assign_form_values(
      interest_rate: @plan.financed_interest_rate,
      term_months: @plan.end_after_count,
      first_due_on: @plan.anchor_date,
      interest_category_id: @plan.financed_interest_category_id
    )
    prepare_form(editing: true)
    render :new
  end

  def update
    @entry = @plan.financed_source_entry
    plan_terms = RecurringTransaction::InstallmentPlanTerms.new(
      plan: @plan,
      interest_rate: plan_params[:interest_rate],
      term_months: plan_params[:term_months],
      first_due_on: first_due_on,
      interest_category_id: plan_params[:interest_category_id]
    ).call

    if plan_terms.errors.none?
      redirect_after_save(t(".success"))
    else
      @plan_errors = plan_terms.errors.full_messages
      assign_form_values(
        interest_rate: plan_params[:interest_rate],
        term_months: plan_params[:term_months],
        first_due_on: first_due_on || @plan.anchor_date,
        interest_category_id: plan_params[:interest_category_id]
      )
      prepare_form(editing: true)
      render :new, status: :unprocessable_entity
    end
  end

  # A small GET endpoint for the dialog's live estimate. It reads the same
  # fields the form will save and runs the loan engine, so the preview cannot
  # disagree with the plan it creates.
  def preview
    @estimate = estimate_for(
      principal: @preview_principal,
      currency: @preview_currency,
      interest_rate: plan_params[:interest_rate],
      term_months: plan_params[:term_months],
      first_due_on: first_due_on
    )

    render partial: "installment_plans/estimate",
           locals: { estimate: @estimate },
           layout: false
  end

  private
    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    def set_plan
      @plan = Current.family.recurring_transactions
                     .accessible_by(Current.user)
                     .find(params[:bill_id])
    end

    def set_preview_parent
      if params[:transaction_id].present?
        set_entry
        @preview_principal = @entry.amount.abs
        @preview_currency = @entry.currency
      else
        set_plan
        @preview_principal = @plan.financed_principal_amount
        @preview_currency = @plan.currency
      end
    end

    def ensure_plan_terms_editable
      return if @plan.financed_terms_editable?

      redirect_to bill_path(@plan), alert: t("installment_plans.terms_locked")
    end

    def assign_form_values(interest_rate:, term_months:, first_due_on: nil,
                           interest_category_id: nil)
      @interest_rate = interest_rate
      @term_months = term_months
      @first_due_on = first_due_on || @entry.date.next_month
      @interest_category_id = interest_category_id
      @categories = Current.family.categories.alphabetically_by_hierarchy.to_a
    end

    def prepare_form(editing:)
      @editing = editing
      @form_url = editing ? bill_installment_plan_path(@plan) : transaction_installment_plan_path(@entry)
      @form_method = editing ? :patch : :post
      @form_title = editing ? t("installment_plans.edit_title") : t("installment_plans.new.title")
      @form_description = editing ? t("installment_plans.edit_description") : t("installment_plans.new.description")
      @submit_label = editing ? t("installment_plans.update_submit") : t("installment_plans.new.submit")
      @preview_url = editing ? preview_bill_installment_plan_path(@plan) : preview_transaction_installment_plan_path(@entry)
      @estimate = estimate_for(
        principal: editing ? @plan.financed_principal_amount : @entry.amount.abs,
        currency: editing ? @plan.currency : @entry.currency,
        interest_rate: @interest_rate,
        term_months: @term_months,
        first_due_on: @first_due_on
      )
    end

    def estimate_for(principal:, currency:, interest_rate:, term_months:, first_due_on:)
      rate = BigDecimal(interest_rate.to_s)
      term = term_months.to_i
      amount = principal.to_d

      return nil unless amount.positive?
      return nil unless rate.finite? && rate >= 0 && rate <= 100
      return nil unless term.positive? && term <= RecurringTransaction::MAX_END_AFTER_COUNT
      return nil if first_due_on.blank?

      schedule = Loan::AmortizationSchedule.new(
        principal: amount,
        annual_rate: rate,
        term_months: term,
        start_date: first_due_on.prev_month,
        currency: currency
      )
      payments = schedule.payments
      return nil if payments.empty?

      {
        monthly_payment: schedule.periodic_payment,
        total_interest: schedule.total_interest,
        count: payments.size
      }
    rescue ArgumentError, TypeError, FloatDomainError
      nil
    end

    # Most families already have an interest or fees category. Offering it as
    # the default keeps the split useful without another setup step; leaving
    # the field blank keeps each charge under the purchase category.
    def default_interest_category_id
      categories = Current.family.categories.alphabetically.to_a

      (categories.find { |category| category.name.match?(/\binterest\b/i) } ||
       categories.find { |category| category.name.match?(/\b(fees?|financ(e|ing))\b/i) })&.id
    end

    def build_plan
      RecurringTransaction::InstallmentPlan.new(
        family: Current.family,
        user: Current.user,
        entry: @entry,
        interest_rate: plan_params[:interest_rate],
        term_months: plan_params[:term_months],
        first_due_on: first_due_on,
        interest_category_id: plan_params[:interest_category_id]
      ).call
    end

    def eligible?
      RecurringTransaction::InstallmentPlan.new(
        family: Current.family,
        user: Current.user,
        entry: @entry,
        interest_rate: nil,
        term_months: nil
      ).eligible?
    end

    def redirect_after_save(message)
      flash[:notice] = message

      respond_to do |format|
        format.html { redirect_to bill_path(@plan) }
        # The form lives in the modal frame, so a plain redirect would make
        # Turbo look for that frame on the bill page. Send a stream redirect
        # instead and let it navigate the whole page.
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, bill_path(@plan)) }
      end
    end

    def first_due_on
      raw = plan_params[:first_due_on].presence
      raw.is_a?(Date) ? raw : Date.parse(raw) if raw
    rescue ArgumentError
      nil
    end

    def plan_params
      params.fetch(:installment_plan, {}).permit(
        :interest_rate,
        :term_months,
        :first_due_on,
        :interest_category_id
      )
    end
end
