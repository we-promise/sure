class SyncsController < ApplicationController
  def cancel
    # for_family with resource_owner scoping: account-level syncs are only
    # reachable for accounts the user can access; cross-family ids 404.
    sync = Sync.for_family(Current.family, resource_owner: Current.user).find(params[:id])

    if sync.request_cancel!
      redirect_back_or_to accounts_path, notice: t(".cancelled")
    else
      redirect_back_or_to accounts_path, alert: t(".not_cancellable")
    end
  end
end
