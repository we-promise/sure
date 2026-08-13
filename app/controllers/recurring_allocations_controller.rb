class RecurringAllocationsController < ApplicationController
  def create
    occurrence = find_occurrence(params[:recurring_occurrence_id])
    entry = find_entry(occurrence, params[:entry_id])

    RecurringTransaction::Allocator.new(occurrence).allocate!(
      entry: entry,
      amount: params[:amount].presence
    )

    redirect_with occurrence, notice: t(".success")
  rescue RecurringTransaction::Allocator::OverAllocationError,
         RecurringTransaction::Allocator::MissingRateError,
         ActiveRecord::RecordInvalid,
         ActiveRecord::RecordNotUnique,
         ArgumentError => e
    redirect_with occurrence, alert: allocation_error_message(e)
  end

  def destroy
    allocation = RecurringAllocation
                   .joins(recurring_occurrence: :recurring_transaction)
                   .where(recurring_occurrences: { family_id: Current.family.id })
                   .merge(RecurringTransaction.accessible_by(Current.user))
                   .find(params[:id])
    occurrence = allocation.recurring_occurrence

    RecurringTransaction::Allocator.new(occurrence).unallocate!(allocation)

    redirect_with occurrence, notice: t(".success")
  end

  private
    def find_occurrence(id)
      Current.family.recurring_occurrences
             .joins(:recurring_transaction)
             .merge(RecurringTransaction.accessible_by(Current.user))
             .find(id)
    end

    def find_entry(occurrence, entry_id)
      return nil if entry_id.blank?

      Current.family.entries.find(entry_id)
    end

    def allocation_error_message(error)
      case error
      when RecurringTransaction::Allocator::OverAllocationError then t("recurring_allocations.over_allocation")
      when RecurringTransaction::Allocator::MissingRateError then t("recurring_allocations.missing_rate")
      when ActiveRecord::RecordNotUnique then t("recurring_allocations.already_allocated")
      else t("recurring_allocations.invalid")
      end
    end

    def redirect_with(occurrence, notice: nil, alert: nil)
      flash[:notice] = notice if notice
      flash[:alert] = alert if alert
      target = occurrence ? recurring_occurrence_path(occurrence) : bills_path

      respond_to do |format|
        format.html { redirect_to target }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, target) }
      end
    end
end
