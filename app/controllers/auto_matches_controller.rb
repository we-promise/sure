class AutoMatchesController < ApplicationController
  layout "settings"

  def index
    @family = Current.family
    @pending_transfers = Transfer.pending
      .where(inflow_transaction_id: accessible_transaction_ids)
      .where(outflow_transaction_id: accessible_transaction_ids)
      .includes(inflow_transaction: { entry: :account }, outflow_transaction: { entry: :account })
      .order(created_at: :desc)
  end

  def update_settings
    Current.family.update!(auto_match_settings_params)

    respond_to do |format|
      format.html do
        flash[:notice] = t(".settings_updated")
        redirect_to auto_matches_path
      end
    end
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
end
