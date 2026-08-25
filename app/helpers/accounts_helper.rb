module AccountsHelper
  def summary_card(title:, &block)
    content = capture(&block)
    render "accounts/summary_card", title: title, content: content
  end

  # The accounts a viewer may actually see, out of a collection a provider card
  # was about to render whole.
  #
  # A provider item is surfaced on the accounts page as soon as ONE of its
  # accounts is accessible (AccountsController#visible_provider_items), but the
  # cards then hand their entire item to accounts/index/_account_groups. A
  # member shared into one account of a connection would otherwise read the
  # names, balances and group totals of the ones nobody shared with them.
  #
  # The manual list already applies this rule upstream, through
  # `where(id: @accessible_account_ids)`, and applies it to everyone: an admin
  # does not see a member's unshared account there either. This keeps the
  # provider cards to the same rule, in the one place they all render through.
  def accounts_visible_to_viewer(accounts)
    ids = viewer_accessible_account_ids
    accounts.select { |account| ids.include?(account.id) }
  end

  # Whether there is a viewer to scope to at all. A background broadcast renders
  # these partials with `Current.user` nil, and "no accessible accounts" and
  # "no viewer" are different answers that the empty-set fallback below
  # collapses into one.
  def viewer_present_for_account_scoping?
    # `nil?`, not `present?`: an injected list that is empty is still a viewer
    # — one who may see nothing, which is a real answer. Treating it as "no
    # viewer" would hand a member with no shared accounts an "Updating…" card
    # that never updates into anything.
    !@accessible_account_ids.nil? || Current.user.present?
  end

  # Reuses the list the accounts index already loaded; falls back to a query for
  # any other caller, once per request.
  def viewer_accessible_account_ids
    @viewer_accessible_account_ids ||=
      (@accessible_account_ids || Current.user&.accessible_accounts&.pluck(:id) || []).to_set
  end

  def sync_path_for(account)
    # Always use the account sync path, which handles syncing all providers
    sync_account_path(account)
  end

  # Returns the account id segment from `/accounts/<id>(/...)?`, or nil.
  # Used as a cache-key component so the sidebar's active-link styling is
  # correct without busting the cache for every unrelated path change.
  def sidebar_active_account_id
    match = request.path.match(%r{\A/accounts/([\w-]+)})
    match && match[1]
  end

  # Cache key for `accounts/_account_sidebar_tabs.html.erb`.
  # Kept here (not in the ERB) so the partial stays render-only.
  #
  # `shares_version` includes both row count and `max(updated_at)` because
  # deleting a non-most-recent share would not move `max(updated_at)` and
  # could otherwise serve stale fragments to a user who lost access.
  # Both are pulled in a single SQL round-trip via `pick`. Note: Rails
  # returns the values as Strings for raw SQL fragments — that's fine
  # since they only feed into a cache key (concat-stable, never coerced).
  def account_sidebar_tabs_cache_key(family:, active_tab:, mobile:)
    shares_version =
      if Current.user
        count, max_at = AccountShare
          .where(user_id: Current.user.id)
          .pick(Arel.sql("count(*)"), Arel.sql("max(updated_at)"))
        "#{count}-#{max_at}"
      end

    [
      family.build_cache_key("account_sidebar_tabs_v2", invalidate_on_data_updates: true),
      Current.user&.id,
      shares_version,
      active_tab,
      mobile,
      I18n.locale,
      sidebar_active_account_id
    ]
  end
end
