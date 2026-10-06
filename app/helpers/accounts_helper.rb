module AccountsHelper
  # Options for the availability select: "automatic" first, naming the level
  # the subtype would give, then the four levels.
  def liquidity_choice_options(account)
    automatic = t("accounts.liquidity.form.automatic", level: t("accounts.liquidity.levels.#{account.default_liquidity}"))

    [ [ automatic, Account::Liquidity::AUTOMATIC ] ] +
      Account::Liquidity::LEVELS.map { |level| [ t("accounts.liquidity.levels.#{level}"), level ] }
  end

  # Subtype => default level for the account's type, so the form can follow a
  # subtype change made before saving. "" stands for "no subtype".
  def liquidity_defaults_by_subtype(account)
    klass = account.accountable_class
    return {} if klass.nil?

    subtypes = klass.const_defined?(:SUBTYPES) ? klass::SUBTYPES.keys : []
    ([ "" ] + subtypes).index_with { |subtype| klass.rules_for(subtype).liquidity }
  end

  # Badge text for the account header, nil when nothing needs saying: an
  # immediately available account carries no badge.
  def liquidity_badge_label(account, date = account.liquidity_today)
    case account.effective_liquidity(date)
    when "short_term" then t("accounts.liquidity.badge.short_term")
    when "long_term" then t("accounts.liquidity.badge.long_term")
    when "locked"
      release = account.next_release_date(date)
      release ? t("accounts.liquidity.badge.locked_until", date: l(release, format: :long)) : t("accounts.liquidity.badge.locked")
    end
  end
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
      family.build_cache_key("account_sidebar_tabs_v3", invalidate_on_data_updates: true),
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
      Current.user&.always_expanded_account_groups&.sort
    ]
  end
end
