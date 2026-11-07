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

  # How long a sidebar sparkline frame may spend fetching before
  # `turbo_frame_timeout_controller` replaces it with a warning badge.
  SPARKLINE_FRAME_TIMEOUT_MS = 10_000

  # Shared by the group-level and the per-account sparkline frames so the two
  # call sites cannot drift apart.
  #
  # Those frames are `loading: "lazy"`: Turbo fetches them when they scroll
  # into view, which can be long after they render, or never, so the countdown
  # has to time the request rather than the element. The frames declare when it
  # starts and when it stops.
  def sparkline_frame_data
    {
      controller: "turbo-frame-timeout",
      action: "turbo:before-fetch-request->turbo-frame-timeout#startTimeout " \
              "turbo:before-frame-render->turbo-frame-timeout#clearTimeout",
      turbo_frame_timeout_timeout_value: SPARKLINE_FRAME_TIMEOUT_MS
    }
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
  # Versions for the sidebar's sparkline URLs, keyed by account id and by group
  # accountable, computed together rather than per account.
  def sidebar_sparkline_versions(family)
    @sidebar_sparkline_versions ||= begin
      groups = family.balance_sheet.account_groups
      Account.sparkline_versions(groups.flat_map(&:accounts).map(&:account))
        .merge(AccountableSparkline.versions(groups.map(&:accountable_type).uniq))
    end
  end

  def account_sidebar_tabs_cache_key(family:, active_tab:, mobile:)
    shares_version =
      if Current.user
        count, max_at = AccountShare
          .where(user_id: Current.user.id)
          .pick(Arel.sql("count(*)"), Arel.sql("max(updated_at)"))
        "#{count}-#{max_at}"
      end

    # Linking or unlinking a provider doesn't touch the account, but changes its sparkline versions.
    providers_version = AccountProvider.where(account_id: family.accounts.select(:id))
      .pick(Arel.sql("count(*)"), Arel.sql("max(account_providers.updated_at)"))

    [
      family.build_cache_key("account_sidebar_tabs_v7", invalidate_on_data_updates: true),
      Current.user&.id,
      shares_version,
      providers_version,
      active_tab,
      mobile,
      I18n.locale,
      # Sparkline URLs carry a version that rolls over with the 30-day window.
      Date.current,
      sidebar_active_account_id,
      # Fold the per-user "start expanded by default" preference into the key
      # so toggling it in Settings busts the 12h fragment cache immediately
      # (this partial renders with skip_digest: true, so the template digest
      # would not otherwise reflect the change).
      Current.user&.always_expanded_account_groups&.sort,
      # Brandfetch logo URLs carry the client id and the logo size, so
      # changing either in Settings must bust the cached sidebar too.
      Digest::SHA256.hexdigest(Setting.brand_fetch_client_id.to_s),
      Setting.brand_fetch_logo_size,
      # Changing the account order, or dragging an account in the manual
      # order, must re-render the sidebar right away rather than after the
      # 12h expiry.
      Current.user&.default_account_order,
      Current.user&.account_order&.manual? ? Digest::SHA256.hexdigest(Current.user.manual_account_order.to_json) : nil
    ]
  end

  # Where the icon shown for the account comes from, for the account form.
  def account_logo_caption(account)
    key = if account.logo_brandfetch? && account.brandfetch_logo_url then "brandfetch"
    elsif account.stored_logo_url then account.logo_source || "uploaded"
    elsif account.brandfetch_logo_url then "brandfetch"
    else "none"
    end

    name = account.logo.blob.metadata["logo_name"] if key == account.logo_source
    [ t("accounts.logo_caption.#{key}"), name ].compact.join(" · ")
  end

  LogoOption = Data.define(:source, :src, :label, :detail, :title, :current)

  # Tiles of the logo picker: the icons found for the domain, the stored logo
  # while Brandfetch is shown instead, and Brandfetch when configured.
  # `source` is what Account#choose_logo receives when the form is saved.
  def account_logo_options(account, candidates)
    shows_stored = account.logo_automatic?

    options = candidates.map do |icon|
      LogoOption.new(
        source: icon.key,
        src: "data:#{icon.content_type};base64,#{Base64.strict_encode64(icon.body)}",
        label: t("accounts.logo_options.sources.#{icon.source}"),
        detail: t("accounts.logo_options.size", size: icon.size),
        title: icon.name,
        current: shows_stored && account.stored_logo?(icon.key, body: icon.body)
      )
    end

    if !shows_stored && account.stored_logo_url
      options.unshift(LogoOption.new(source: "stored", src: account.stored_logo_url, label: t("accounts.logo_options.stored"),
                                     detail: nil, title: nil, current: false))
    end

    if account.brandfetch_logo_url
      options << LogoOption.new(source: "brandfetch", src: account.brandfetch_logo_url, label: t("accounts.logo_options.sources.brandfetch"),
                                detail: nil, title: nil, current: !shows_stored || !account.logo.attached?)
    end

    options
  end
end
