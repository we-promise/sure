class RecurringAllocationsController < ApplicationController
  def create
    occurrence = find_occurrence(params[:recurring_occurrence_id])
    entry = find_entry(occurrence, params[:entry_id])

    RecurringTransaction::Allocator.new(occurrence).allocate!(
      entry: entry,
      amount: params[:amount].presence,
      # A manual payment already defaults to today (RecurringAllocation's
      # default_paid_on callback). Accepting a date lets someone record the
      # payment they made last Tuesday as last Tuesday.
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

    RecurringTransaction::Allocator.new(occurrence).unallocate!(allocation)

    redirect_with notice: t(".success")
  end

  def confirm
    allocation = find_allocation
    occurrence = allocation.recurring_occurrence

    RecurringTransaction::Allocator.new(occurrence).confirm_suggestion!(allocation)

    redirect_with_return notice: t(".success")
  end

  def reject
    allocation = find_allocation
    occurrence = allocation.recurring_occurrence

    RecurringTransaction::Allocator.new(occurrence).reject_suggestion!(allocation)

    redirect_with_return notice: t(".success")
  end

  private
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

      respond_to do |format|
        format.html { redirect_back_or_to bills_path }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, request.referer || bills_path) }
      end
    end

    def find_occurrence(id)
      Current.family.recurring_occurrences
             .joins(:recurring_transaction)
             .merge(RecurringTransaction.accessible_by(Current.user))
             .find(id)
    end

    # Scoped to what this user can actually see, like every other lookup here:
    # sharing is per account, so a family scope alone would let a member pay a
    # bill with a transaction from an account they were never given.
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

    # Back to the worklist, not back to the occurrence.
    #
    # A plain GET of recurring_occurrence_path renders the "settings" layout,
    # and that layout renders layouts/shared/_htmldoc, which already emits an
    # empty <turbo-frame id="drawer">. The dialog then emits its own frame with
    # the same id, so the page carries two elements sharing one id and the next
    # navigation into that frame lands in the empty one. This is the two-frames
    # trap RecurringTransactionsController#edit documents.
    #
    # The worklist row already shows the new state, which is what "see the
    # result" means here, so there is nothing to gain by going back to a dialog
    # floating over an otherwise empty page.
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
