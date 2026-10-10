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
    #
    # This is the early refusal, before any work is done. It is NOT the
    # authorization that protects the mutation -- see #relinking below for why
    # the answer it gives cannot be trusted by the time the link moves.
    def require_relinkable_provider_account!(provider_account, target_account)
      relink_holders_authorized?(provider_account, target_account)
    end

    # The question both checks ask. Named separately from the early refusal so
    # the two call sites are distinguishable -- a test can answer the pre-lock
    # one the way a stale read would and still watch the real one run.
    def relink_holders_authorized?(provider_account, target_account)
      provider_link_holders(provider_account).each do |holder|
        next if holder == target_account
        return false unless require_account_permission!(holder, :write, redirect_path: accounts_path)
      end
      true
    end

    # Runs a relink with the holder authorized at the moment it is moved.
    #
    # #require_relinkable_provider_account! reads the mapping before the
    # provider row is locked. Between that read and the lock another request
    # can point the provider at a different account -- one this user cannot
    # write. The block then moves the link off whatever the mapping names
    # *now*, and several providers queue that account for deletion, so the
    # pre-lock answer is about an account that is no longer the one at risk.
    #
    # Inside the lock the mapping is read again and the holders it actually
    # names are authorized again. A refusal raises, so the transaction rolls
    # back: nothing is moved, nothing is queued for deletion, and the redirect
    # #require_account_permission! has already set is what the user gets.
    #
    # Returns true when the block ran, false when the relink was refused. Every
    # relinking path goes through it, so a new provider cannot reintroduce the
    # window by writing its own transaction.
    def relinking(provider_account, target_account)
      refused = false

      Account.transaction do
        # lock! reloads, which clears the association cache, so the holders
        # read below come from inside the lock rather than from before it.
        provider_account.lock!

        unless relink_holders_authorized?(provider_account, target_account)
          refused = true
          raise ActiveRecord::Rollback
        end

        yield
      end

      !refused
    end

    # Select dialogs that offer already-linked provider accounts must not offer,
    # or name, an account the user cannot write.
    def relinkable_by_current_user?(provider_account)
      provider_link_holders(provider_account).all? { |holder| writable_account_ids.include?(holder.id) }
    end

    # Resolved once per request through Account.writable_by, the app-wide
    # definition of write access, so a dialog listing many linked accounts
    # does not run a share lookup per row.
    def writable_account_ids
      @writable_account_ids ||= Current.family.accounts.writable_by(Current.user).pluck(:id).to_set
    end

    # The AccountProvider link, plus the legacy foreign key some providers
    # (SimpleFIN, Plaid) still carry.
    def provider_link_holders(provider_account)
      [ provider_account.account_provider&.account, provider_account.try(:account) ].compact.uniq
    end
end
