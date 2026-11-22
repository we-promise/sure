class AutoMatchesController < ApplicationController
  layout "settings"

  # The toggle is family-wide and turning it off destroys every pending
  # suggestion, including ones between other members' private accounts.
  before_action :require_admin!, only: :update_settings

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
    family = Current.family
    was_disabled = family.auto_match_transfers_disabled?

    # One transaction, so a failed cleanup doesn't leave auto match off with
    # some suggestions still pending.
    Family.transaction do
      if params.key?(:auto_match_transfers_disabled)
        family.update!(auto_match_transfers_disabled: params[:auto_match_transfers_disabled] == "true")
        cleanup_pending_auto_matches! if !was_disabled && family.auto_match_transfers_disabled?
      end

      if params.key?(:require_transfer_match_confirmation)
        required = params[:require_transfer_match_confirmation] == "true"
        family.update_transfer_match_confirmation!(required) unless required == family.require_transfer_match_confirmation?
      end
    end
    # Re-enabling should have an immediate effect rather than waiting for the
    # next scheduled sync -- run the (potentially slow, family-wide) match
    # scan in the background instead of blocking this request.
    AutoMatchTransfersJob.perform_later(family) if was_disabled && !family.auto_match_transfers_disabled?

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
        # Reloads under a row lock, so a match a concurrent request already
        # confirmed or rejected is skipped instead of being resolved twice.
        transfer.with_lock do
          next unless transfer.pending?

          status == "confirmed" ? transfer.confirm! : transfer.reject!
          updated_count += 1
        end
      rescue ActiveRecord::RecordNotFound
        # Already rejected (destroyed) by a concurrent action; skip it and
        # keep going through the rest of the selection.
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

    # Turning the toggle off stops future matching but previously suggested
    # pending matches would otherwise sit in the list (and on the
    # transaction rows) indefinitely. Destroy rather than reject!: reject!
    # writes a RejectedTransfer row that permanently excludes the pair from
    # future auto-matching (auto_match_transfers! runs with
    # include_rejected: false), which would surprise a user who re-enables
    # the toggle later expecting the same pairs to resurface.
    def cleanup_pending_auto_matches!
      # Only clean up genuine auto-match suggestions (Transfer#match_suggestion?).
      # A pending transfer imported with kinds of its own (Family::DataImporter)
      # isn't one, even when those kinds equal the ones a match would give, so
      # the toggle leaves it in place.
      Current.family.pending_transfer_matches.find_each do |transfer|
        transfer.destroy! if transfer.match_suggestion?
      end
    end

    def bulk_update_params
      params.permit(:status, transfer_ids: [])
    end
end
