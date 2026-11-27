# Data-quality and connection problems on one account, shown next to its sync
# state on the account page. Each check returns an Issue or nil (a list for
# provider connections); a new one is a private `*_issue` method added to
# `issues`. Details stay data (negative positions); UI::Account::HealthStatus
# formats them for the viewer's family.
#
# Computed for the account the viewer opened, so it is only ever shown to
# someone who can see that account. The viewer decides what an issue offers to
# do about it, such as whether they may reconnect a provider connection.
class Account::HealthStatus
  Issue = Data.define(:severity, :message, :details, :hint, :link) do
    def initialize(severity:, message:, details: [], hint: nil, link: nil)
      super
    end
  end

  attr_reader :account, :viewer

  def initialize(account, viewer: nil)
    @account = account
    @viewer = viewer
  end

  def issues
    @issues ||= [ *provider_reconnect_issues, sync_issue, negative_positions_issue ].compact
  end

  private
    # An expired sign-in fails the connection's sync, not the account's, so
    # sync_issue never sees it. Whoever may reconnect gets a link to where that
    # happens; everyone else is told to ask an admin.
    def provider_reconnect_issues
      reconnect_items.map do |item, provider_name|
        link = reconnect_link(item)
        Issue.new(
          severity: :warning,
          message: I18n.t("accounts.health_status.provider_reconnect.message", provider: item.try(:institution_display_name).presence || item.try(:name).presence || provider_name.humanize),
          hint: I18n.t(link ? "accounts.health_status.provider_reconnect.hint" : "accounts.health_status.provider_reconnect.hint_ask_admin"),
          link: link
        )
      end
    end

    # Where a signed-out connection is repaired. Plaid (through Plaid Link) and
    # SimpleFIN (with a new setup token) reconnect from their card on the
    # accounts page; the bank sync settings page can't do that for them. Every
    # other connection is repaired in its panel on that settings page, which
    # lists it among the connections needing attention and is admin-only.
    def reconnect_link(item)
      return unless reconnectable_by_viewer?(item)

      routes = Rails.application.routes.url_helpers
      if item.is_a?(PlaidItem) || item.is_a?(SimplefinItem)
        { text: I18n.t("accounts.health_status.provider_reconnect.link_accounts"), href: routes.accounts_path(anchor: ActionView::RecordIdentifier.dom_id(item)) }
      elsif viewer.admin?
        { text: I18n.t("accounts.health_status.provider_reconnect.link_bank_sync"), href: routes.settings_providers_path }
      end
    end

    # A connection with its own owner (Plaid) may be reconnected by a member who
    # owns it; every other one by admins only, as its controller requires.
    def reconnectable_by_viewer?(item)
      return item.manageable_by?(viewer) if item.respond_to?(:manageable_by?)

      viewer&.admin? == true
    end

    # Includes connections still linked through the legacy plaid_account /
    # simplefin_account columns: such an account may have no AccountProvider,
    # and a signed-out connection's sync never gets far enough to add one.
    def reconnect_items
      linked = account.account_providers.filter_map do |account_provider|
        item = account_provider.adapter.try(:item)
        [ item, account_provider.provider_name ] if item
      end
      linked << [ account.plaid_account.plaid_item, "plaid" ] if account.plaid_account&.plaid_item
      linked << [ account.simplefin_account.simplefin_item, "simplefin" ] if account.simplefin_account&.simplefin_item

      linked.uniq(&:first).select { |item, _| ProviderConnectionStatus.requires_update?(item) }
    end

    # The account's own latest sync: a later one that went through clears it.
    # One still pending past Sync::VISIBLE_FOR lost its job; Sync.clean only
    # marks it stale a day later.
    def sync_issue
      sync = account.latest_sync_record
      return unless sync
      return unless sync.failed? || sync.stale? || (sync.in_progress? && !sync.visible?)

      key = sync.failed? ? :sync_failed : :sync_stale
      Issue.new(
        severity: sync.failed? ? :error : :warning,
        message: I18n.t("accounts.health_status.#{key}.message"),
        hint: I18n.t("accounts.health_status.sync_hint")
      )
    end

    def negative_positions_issue
      positions = account.negative_positions
      return if positions.empty?

      Issue.new(
        severity: :warning,
        message: I18n.t("accounts.health_status.negative_positions.message"),
        details: positions,
        hint: I18n.t("accounts.health_status.negative_positions.hint"),
        link: { text: I18n.t("accounts.health_status.negative_positions.link"), href: Rails.application.routes.url_helpers.account_path(account, tab: "holdings") }
      )
    end
end
