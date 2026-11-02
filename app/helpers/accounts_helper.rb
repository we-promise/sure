module AccountsHelper
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
  #
  # They are also data-turbo-permanent with a versioned id (see
  # `sidebar_sparkline_frame_id`); `permanent_frame_controller` releases a
  # stale one on a morph refresh.
  def sparkline_frame_data
    {
      turbo_permanent: true,
      controller: "turbo-frame-timeout permanent-frame",
      action: "turbo:before-fetch-request->turbo-frame-timeout#startTimeout " \
              "turbo:before-frame-render->turbo-frame-timeout#clearTimeout " \
              "turbo:fetch-request-error->turbo-frame-timeout#handleError",
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
  # The account share version comes from `Current.account_share_version`, the
  # same source the sidebar sparkline frame ids use, so a change in the user's
  # account access moves both together.
  def account_sidebar_tabs_cache_key(family:, active_tab:, mobile:)
    [
      family.build_cache_key("account_sidebar_tabs_v6", invalidate_on_data_updates: true),
      Current.user&.id,
      Current.account_share_version,
      active_tab,
      mobile,
      I18n.locale,
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

  # Data version for the sidebar's sparkline frames. It is built from the same
  # inputs as the sparkline ETags (latest sync + account updates), so it moves
  # exactly when a sparkline could change. Computed once per sidebar render.
  def sidebar_sparkline_version(family)
    # Per user and share version too: which accounts a group sparkline covers
    # depends on the viewer's account shares.
    key = [
      family.build_cache_key("sidebar_sparklines_#{Account::Chartable::SPARKLINE_CACHE_VERSION}", invalidate_on_data_updates: true),
      Current.user&.id,
      Current.account_share_version
    ].join("_")
    Digest::SHA256.hexdigest(key).first(12)
  end

  # DOM id for a sparkline frame in the sidebar. The sidebar renders each group
  # and account up to four times (All tab + type tab, desktop + mobile), so the
  # id carries the placement to stay unique. The frames are
  # data-turbo-permanent: a loaded sparkline survives Turbo navigations while
  # its id is unchanged, and the data version in the id makes a sync render new
  # frames that load fresh.
  def sidebar_sparkline_frame_id(base_id, all_tab:, mobile:, version:)
    [ ("mobile" if mobile), (all_tab ? "all" : "tab"), base_id, version ].compact.join("_")
  end

  # Frame id for a sparkline response: echoes the requesting frame's id so
  # Turbo can match it, falling back to the base id for direct requests.
  def sparkline_response_frame_id(base_id)
    requested = turbo_frame_request_id.to_s
    pattern = /\A(?:mobile_)?(?:all|tab)_#{Regexp.escape(base_id)}_[0-9a-f]{12}\z/
    requested.match?(pattern) ? requested : base_id
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
