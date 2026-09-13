# Authorization for linking a provider account to an existing account.
#
# require_admin! is a family-role check, not an account one. Attaching a
# provider writes to the account, which needs owner or full_control;
# auto_share_with_family! only grants members read_write. Every
# select_existing_account / link_existing_account goes through these so the
# providers cannot drift apart again (#3534).
module ProviderAccountLinking
  extend ActiveSupport::Concern

  private
    # The account receiving the link.
    def require_linkable_account!(account)
      require_account_permission!(account, :write, redirect_path: accounts_path)
    end

    # Relinking moves the provider off the account that holds it, and some
    # providers then schedule that account for deletion, so it needs :write too.
    def require_relinkable_provider_account!(provider_account, target_account)
      provider_link_holders(provider_account).each do |holder|
        next if holder == target_account
        return false unless require_account_permission!(holder, :write, redirect_path: accounts_path)
      end
      true
    end

    # Select dialogs that offer already-linked provider accounts must not offer,
    # or name, an account the user cannot write.
    def relinkable_by_current_user?(provider_account)
      provider_link_holders(provider_account).all? { |holder| writable_account_ids.include?(holder.id) }
    end

    # Owner or full_control, the rule require_account_permission!(:write)
    # applies, resolved once per request so a dialog listing many linked
    # accounts does not run a share lookup per row.
    def writable_account_ids
      @writable_account_ids ||= begin
        full_control_ids = AccountShare.where(user_id: Current.user.id, permission: "full_control").select(:account_id)
        Current.family.accounts.where(owner_id: Current.user.id)
          .or(Current.family.accounts.where(id: full_control_ids))
          .pluck(:id).to_set
      end
    end

    # The AccountProvider link, plus the legacy foreign key some providers
    # (SimpleFIN, Plaid) still carry.
    def provider_link_holders(provider_account)
      [ provider_account.account_provider&.account, provider_account.try(:account) ].compact.uniq
    end
end
