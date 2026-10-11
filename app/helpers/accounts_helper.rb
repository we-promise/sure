module AccountsHelper
  def summary_card(title:, &block)
    content = capture(&block)
    render "accounts/summary_card", title: title, content: content
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
      family.build_cache_key("account_sidebar_tabs_v5", invalidate_on_data_updates: true),
      Current.user&.id,
      shares_version,
      active_tab,
      mobile,
      I18n.locale,
      sidebar_active_account_id,
      # Fold the per-user "start expanded by default" preference into the key
      # so toggling it in Settings busts the 12h fragment cache immediately
      # (this partial renders with skip_digest: true, so the template digest
      # would not otherwise reflect the change).
      Current.user&.always_expanded_account_groups&.sort,
      account_grouping_primary(:sidebar),
      account_grouping_dimension(:sidebar)
    ]
  end

  # The first grouping dimension for an account list view (default: account
  # type). Preview-only for now.
  def account_grouping_primary(view)
    return AccountGrouping::DEFAULT_PRIMARY unless Current.user&.preview_features_enabled?

    Current.user.account_grouping_primary_for(view)
  end

  # First-level account groups of a balance sheet or one of its
  # classification groups, as chosen for the given view.
  def account_groups_for(source, view:)
    source.account_groups(by: account_grouping_primary(view), user: Current.user)
  end

  # Sections of the sidebar's "All" tab as [classification group or nil,
  # account groups]. Grouped by account type, every group belongs to one side,
  # so the tab stays one flat list. Grouped by another field, the same value
  # (e.g. "Not set" or one owner) forms a group among assets and among debts,
  # so each side gets its own section instead of two rows with one name.
  def account_group_sections_for(balance_sheet, view:)
    if account_grouping_primary(view) == AccountGrouping::DEFAULT_PRIMARY
      return [ [ nil, account_groups_for(balance_sheet, view: view) ] ]
    end

    balance_sheet.classification_groups.filter_map do |classification_group|
      groups = account_groups_for(classification_group, view: view)
      [ classification_group, groups ] if groups.any?
    end
  end

  # The second grouping dimension for an account list view, or nil when the
  # view groups by account type only. Preview-only for now. Reads the flag
  # from Current.user so the helper also works outside a controller render.
  def account_grouping_dimension(view)
    return nil unless Current.user&.preview_features_enabled?

    Current.user&.account_grouping_for(view)
  end

  # Subgroups to render inside a first-level group for the given view, or
  # an empty array when the view has no second level (see AccountGrouping).
  def account_subgroups(account_group, view:)
    dimension = account_grouping_dimension(view)
    return [] unless dimension

    account_group.subgroups(dimension, user: Current.user)
  end

  # Values already used for the custom group field on accounts the user can
  # see, offered as suggestions in the account form.
  def account_custom_group_suggestions
    return [] unless Current.user

    Current.user.accessible_accounts
      .where.not(custom_group: nil)
      .distinct
      .order(:custom_group)
      .pluck(:custom_group)
  end
end
