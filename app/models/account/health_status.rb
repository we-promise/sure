# Data-quality and connection problems on one account, shown next to its sync
# state on the account page. Each check returns an Issue or nil (a list for
# provider connections); a new one is a private `*_issue` method added to
# `issues`. Details stay data (negative positions); UI::Account::HealthStatus
# formats them for the viewer's family.
#
# Computed for the account the viewer opened, so it is only ever shown to
# someone who can see that account. The viewer decides what an issue offers to
# do about it: only admins can reconnect a provider connection.
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
    # sync_issue never sees it. Admins reconnect on the connection's card on
    # the accounts page; everyone else is told to ask one.
    def provider_reconnect_issues
      can_reconnect = viewer&.admin?

      reconnect_items.map do |item, provider_name|
        Issue.new(
          severity: :warning,
          message: I18n.t("accounts.health_status.provider_reconnect.message", provider: item.try(:institution_display_name).presence || item.try(:name).presence || provider_name.humanize),
          hint: I18n.t(can_reconnect ? "accounts.health_status.provider_reconnect.hint" : "accounts.health_status.provider_reconnect.hint_ask_admin"),
          link: (reconnect_link(item) if can_reconnect)
        )
      end
    end

    def reconnect_link(item)
      {
        text: I18n.t("accounts.health_status.provider_reconnect.link"),
        href: Rails.application.routes.url_helpers.accounts_path(anchor: ActionView::RecordIdentifier.dom_id(item))
      }
    end

    def reconnect_items
      account.account_providers.filter_map do |account_provider|
        item = account_provider.adapter.try(:item)
        [ item, account_provider.provider_name ] if item && ProviderConnectionStatus.requires_update?(item)
      end.uniq(&:first)
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
