class SyncsController < ApplicationController
  def cancel
    # for_family with resource_owner scoping: account-level syncs are only
    # reachable for accounts the user can access; cross-family ids 404.
    sync = Sync.for_family(Current.family, resource_owner: Current.user).find(params[:id])

    # resource_owner only scopes the Account branch of for_family — provider
    # item syncs match for every member, including accounts a restricted
    # member cannot see. Provider connections are admin-managed surfaces, so
    # cancelling their syncs requires admin too. Family- and account-level
    # syncs stay member-cancellable (the accounts page shows those buttons
    # to every member).
    unless sync.syncable.is_a?(Account) || sync.syncable.is_a?(Family) || Current.user.admin?
      raise ActiveRecord::RecordNotFound
    end

    if sync.request_cancel!
      redirect_back_or_to accounts_path, notice: t(".cancelled")
    else
      redirect_back_or_to accounts_path, alert: t(".not_cancellable")
    end
  end
end
