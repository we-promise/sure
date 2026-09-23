class AutoMatchesController < ApplicationController
  layout "settings"

  def index
    @family = Current.family
    scope = Transfer.pending
      .where(inflow_transaction_id: accessible_transaction_ids)
      .where(outflow_transaction_id: accessible_transaction_ids)
      .includes(inflow_transaction: [ { entry: :account }, :merchant ], outflow_transaction: [ { entry: :account }, :merchant ])
      .order(created_at: :desc)
    @pagy, @pending_transfers = pagy(scope, limit: safe_per_page)
    # Confirm/reject write to both legs (TransfersController#update), so a
    # read-only sharer -- accessible but not writable -- would see dead CTAs
    # that just bounce with a flash. Precompute which accounts they can
    # actually write to, mirroring TransfersController#show's writable check.
    @writable_account_ids = Account.writable_by(Current.user).where(family: @family).ids.to_set
  end

  def update_settings
    was_disabled = Current.family.auto_match_transfers_disabled?
    Current.family.update!(auto_match_settings_params)
    cleanup_pending_auto_matches! if !was_disabled && Current.family.auto_match_transfers_disabled?

    respond_to do |format|
      format.html do
        flash[:notice] = t(".settings_updated")
        redirect_to auto_matches_path
      end
    end
  end

  def bulk_update
    status = bulk_update_params[:status]
    transfer_ids = Array(bulk_update_params[:transfer_ids]).reject(&:blank?)

    unless %w[confirmed rejected].include?(status) && transfer_ids.present?
      redirect_to auto_matches_path, alert: t(".invalid_selection")
      return
    end

    writable_account_ids = Account.writable_by(Current.user).where(family: Current.family).ids.to_set

    transfers = Transfer.pending
      .where(id: transfer_ids)
      .where(inflow_transaction_id: accessible_transaction_ids)
      .where(outflow_transaction_id: accessible_transaction_ids)
      .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })

    updated_count = 0
    transfers.each do |transfer|
      next unless writable_account_ids.include?(transfer.from_account&.id) &&
                  writable_account_ids.include?(transfer.to_account&.id)

      begin
        status == "confirmed" ? transfer.confirm! : transfer.reject!
        updated_count += 1
      rescue ActiveRecord::RecordNotFound
        # Already resolved by a concurrent action; skip it and keep going
        # through the rest of the selection.
        next
      end
    end

    notice = status == "confirmed" ? t(".bulk_confirmed", count: updated_count) : t(".bulk_rejected", count: updated_count)
    redirect_to auto_matches_path, notice: notice
  end

  private
    def accessible_transaction_ids
      Current.family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(Current.user))
        .select(:id)
    end

    def auto_match_settings_params
      { auto_match_transfers_disabled: params[:auto_match_transfers_disabled] == "true" }
    end

    # Turning the toggle off stops future matching but previously suggested
    # pending matches would otherwise sit in the list (and on the
    # transaction rows) indefinitely. Destroy rather than reject!: reject!
    # writes a RejectedTransfer row that permanently excludes the pair from
    # future auto-matching (auto_match_transfers! runs with
    # include_rejected: false), which would surprise a user who re-enables
    # the toggle later expecting the same pairs to resurface.
    def cleanup_pending_auto_matches!
      family_transaction_ids = Current.family.transactions.select(:id)
      Transfer.pending
        .where(inflow_transaction_id: family_transaction_ids)
        .where(outflow_transaction_id: family_transaction_ids)
        .find_each(&:destroy!)
    end

    def bulk_update_params
      params.permit(:status, transfer_ids: [])
    end
end
