module AccountsHelper
  def summary_card(title:, &block)
    content = capture(&block)
    render "accounts/summary_card", title: title, content: content
  end

  # Human list of what a card twin removal would carry onto the surviving row.
  # Lives here rather than in the template so the view holds no domain logic.
  def candidate_carried_fields(candidate)
    fields = []
    fields << t("accounts.card_twin_cleanups.show.carried_category", name: candidate.category.name) if candidate.category.present?
    fields << t("accounts.card_twin_cleanups.show.carried_tags", count: candidate.tag_ids.size) if candidate.tag_ids.any?
    fields << t("accounts.card_twin_cleanups.show.carried_notes") if candidate.notes.present?
    fields
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
