class RecurringAllocationsController < ApplicationController
  include RecurringFeatureGuardable

  before_action :ensure_recurring_enabled

  def create
    occurrence = find_occurrence(params[:recurring_occurrence_id])
    ensure_series_writable(occurrence)
    entry = find_entry(occurrence, params[:entry_id])

    RecurringTransaction::Allocator.new(occurrence).allocate!(
      entry: entry,
      amount: params[:amount].presence,
      # Defaults to today via RecurringAllocation's callback; accepting a date
      # lets someone record last Tuesday's payment as last Tuesday.
      paid_on: params[:paid_on].presence
    )

    redirect_with notice: t(".success")
  rescue RecurringTransaction::Allocator::OverAllocationError,
         RecurringTransaction::Allocator::MissingRateError,
         ActiveRecord::RecordInvalid,
         ActiveRecord::RecordNotUnique,
         ArgumentError => e
    redirect_with alert: allocation_error_message(e)
  end

  def destroy
    allocation = find_allocation
    occurrence = allocation.recurring_occurrence
    ensure_series_writable(occurrence)

    RecurringTransaction::Allocator.new(occurrence).unallocate!(allocation)

    redirect_with notice: t(".success")
  end

  def confirm
    allocation = find_allocation
    occurrence = allocation.recurring_occurrence
    ensure_series_writable(occurrence)

    RecurringTransaction::Allocator.new(occurrence).confirm_suggestion!(allocation)

    redirect_with_return notice: t(".success")
  end

  def reject
    allocation = find_allocation
    occurrence = allocation.recurring_occurrence
    ensure_series_writable(occurrence)

    RecurringTransaction::Allocator.new(occurrence).reject_suggestion!(allocation)

    redirect_with_return notice: t(".success")
  end

  private
    # Reading a shared bill is fine; changing its payment state is not. Sharing
    # is per account, so a read-only account share must not mutate. Accountless
    # series carry no account gate.
    def ensure_series_writable(occurrence)
      series = occurrence.recurring_transaction
      return if series.account_id.nil?
      return if Account.writable_by(Current.user).where(id: series.account_id).exists?

      raise ActiveRecord::RecordNotFound
    end

    def find_allocation
      RecurringAllocation
        .joins(recurring_occurrence: :recurring_transaction)
        .where(recurring_occurrences: { family_id: Current.family.id })
        .merge(RecurringTransaction.accessible_by(Current.user))
        .find(params[:id])
    end

    # Queue actions come from the Bills page and should land back there.
    def redirect_with_return(notice:)
      flash[:notice] = notice
      target = safe_return_path

      respond_to do |format|
        format.html { redirect_to target }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, target) }
      end
    end

    # The referer is request input: only a same-host referer may become a
    # redirect target, matching what redirect_back_or_to enforces.
    def safe_return_path
      referer = request.referer
      return bills_path if referer.blank?

      uri = URI.parse(referer)
      uri.host.nil? || uri.host == request.host ? referer : bills_path
    rescue URI::InvalidURIError
      bills_path
    end

    def find_occurrence(id)
      Current.family.recurring_occurrences
             .joins(:recurring_transaction)
             .merge(RecurringTransaction.accessible_by(Current.user))
             .find(id)
    end

    # Scoped to what this user can see: sharing is per account, so a family
    # scope alone would let a member pay with another account's transaction.
    def find_entry(occurrence, entry_id)
      return nil if entry_id.blank?

      Current.accessible_entries.find(entry_id)
    end

    def allocation_error_message(error)
      case error
      when RecurringTransaction::Allocator::OverAllocationError then t("recurring_allocations.over_allocation")
      when RecurringTransaction::Allocator::MissingRateError then t("recurring_allocations.missing_rate")
      when ActiveRecord::RecordNotUnique then t("recurring_allocations.already_allocated")
      else t("recurring_allocations.invalid")
      end
    end

    # Back to the worklist, not the occurrence: a plain GET of
    # recurring_occurrence_path renders the settings layout, which already emits
    # an empty <turbo-frame id="drawer">, so the page would carry two frames
    # sharing one id. See the two-frames trap in
    # RecurringTransactionsController#edit.
    def redirect_with(notice: nil, alert: nil)
      flash[:notice] = notice if notice
      flash[:alert] = alert if alert
      target = bills_path

      respond_to do |format|
        format.html { redirect_to target }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, target) }
      end
    end
end
