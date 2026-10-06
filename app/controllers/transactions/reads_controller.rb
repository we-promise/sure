# "Mark all as read" for the unread dots, plus marking specific rows read once
# a prefetched list is displayed. On an account page it covers that
# account; on the transactions page it covers the active filters, or
# everything when no filter is set.
class Transactions::ReadsController < ApplicationController
  def create
    # Sent by the unread-marker Stimulus controller when a prefetched list is shown.
    if params[:entry_ids].present?
      Current.user.mark_entries_read!(Current.user.unread_entries.where(id: Array(params[:entry_ids])).pluck(:id))
      head :no_content
    elsif params[:account_id].present?
      account = Current.user.accessible_accounts.find(params[:account_id])
      Current.user.mark_all_transactions_read!(account.entries)
      redirect_back_or_to account_path(account), notice: t(".success")
    elsif filter_params.present?
      search = Transaction::Search.new(
        Current.family,
        filters: filter_params,
        accessible_account_ids: Current.user.accessible_accounts.pluck(:id),
        user: Current.user
      )
      Current.user.mark_all_transactions_read!(Entry.where(id: search.transactions_scope.select("entries.id")))
      redirect_back_or_to transactions_path, notice: t(".success")
    else
      Current.user.mark_all_transactions_read!
      redirect_back_or_to transactions_path, notice: t(".success")
    end
  end

  private
    def filter_params
      params.fetch(:q, {})
            .permit(
              :start_date, :end_date, :search, :amount,
              :amount_operator, :active_accounts_only,
              accounts: [], account_ids: [],
              categories: [], merchants: [], types: [], tags: [], status: []
            )
            .to_h
            .compact_blank
    end
end
