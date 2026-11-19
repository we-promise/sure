# Data-quality problems on one account, shown next to its sync state on the
# account page. Each check returns an Issue or nil; a new one is a private
# `*_issue` method added to `issues`.
#
# Computed for the account the viewer opened, so it is only ever shown to
# someone who can see that account.
class Account::HealthStatus
  Issue = Data.define(:severity, :message, :details, :hint, :link) do
    def initialize(severity:, message:, details: [], hint: nil, link: nil)
      super
    end
  end

  attr_reader :account

  def initialize(account)
    @account = account
  end

  def issues
    @issues ||= [ sync_issue, negative_positions_issue ].compact
  end

  private
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
        details: positions.map { |position| negative_position_detail(position) },
        hint: I18n.t("accounts.health_status.negative_positions.hint"),
        link: { text: I18n.t("accounts.health_status.negative_positions.link"), href: Rails.application.routes.url_helpers.account_path(account, tab: "holdings") }
      )
    end

    def negative_position_detail(position)
      I18n.t(
        "accounts.health_status.negative_positions.detail",
        name: position.security.name.presence || position.security.ticker,
        ticker: position.security.ticker,
        date: I18n.l(position.first_date),
        qty: ActiveSupport::NumberHelper.number_to_rounded(position.lowest_qty, precision: 18, strip_insignificant_zeros: true)
      )
    end
end
