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
      Current.user.mark_all_transactions_read!(account.entries, as_of: as_of)
      redirect_back_or_to account_path(account), notice: t(".success")
    elsif filter_params.present?
      search = Transaction::Search.new(
        Current.family,
        filters: filter_params,
        accessible_account_ids: Current.user.accessible_accounts.pluck(:id),
        user: Current.user
      )
      Current.user.mark_all_transactions_read!(Entry.where(id: search.transactions_scope.select("entries.id")), as_of: as_of)
      redirect_back_or_to transactions_path, notice: t(".success")
    else
      Current.user.mark_all_transactions_read!(as_of: as_of)
      redirect_back_or_to transactions_path, notice: t(".success")
    end
  end

  private
    # When the page with the button was rendered. Transactions synced after it
    # were never shown and stay unread. Without a usable value it falls back to
    # now; User#mark_all_transactions_read! caps it at now.
    def as_of
      Time.zone.iso8601(params[:as_of].to_s)
    rescue ArgumentError
      Time.current
    end

    # The same cleaning as the list, so "mark all" covers exactly the list the
    # user sees. A dropped filter would widen the scope.
    def filter_params
      @filter_params ||= Transaction::Search.clean_filters(params.fetch(:q, {}))
    end
end
