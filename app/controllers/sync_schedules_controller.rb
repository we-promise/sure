# The per-connection sync schedule, edited from the connection's card menu
# on the accounts page. The connection itself is addressed by type and id,
# since every provider keeps its own *_items table.
class SyncSchedulesController < ApplicationController
  before_action :set_syncable

  def edit
    @sync_schedule = @syncable.sync_schedule || @syncable.build_sync_schedule
  end

  def update
    # Blank is the form's "no schedule" choice; a request without the field
    # is malformed and must not delete anything.
    return head :unprocessable_entity unless sync_schedule_params.key?(:interval_minutes)

    interval = sync_schedule_params[:interval_minutes].presence

    if interval.nil?
      @syncable.sync_schedule&.destroy!
      redirect_to accounts_path, notice: t(".cleared")
    else
      @sync_schedule = SyncSchedule.assign(@syncable, interval)

      if @sync_schedule.errors.none?
        redirect_to accounts_path, notice: t(".updated")
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  private
    def sync_schedule_params
      params.fetch(:sync_schedule, {}).permit(:interval_minutes)
    end

    # Looked up through the family's own association, so a type outside the
    # schedulable set or an id from another family is a 404.
    def set_syncable
      association = SyncSchedule.schedulable_associations.fetch(params[:syncable_type].to_s) do
        raise ActiveRecord::RecordNotFound
      end
      @syncable = Current.family.public_send(association).find(params[:syncable_id])
      raise ActiveRecord::RecordNotFound if @syncable.try(:scheduled_for_deletion?)

      # The same check the card's menu uses to offer the entry.
      return if SyncSchedule.editable_by?(@syncable, Current.user)

      respond_to do |format|
        format.html { redirect_to accounts_path, alert: t("shared.require_admin") }
        format.any { head :forbidden }
      end
    end
end
