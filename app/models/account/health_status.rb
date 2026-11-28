# Data-quality problems on one account, shown next to its sync state on the
# account page. Each check returns an Issue or nil; a new one is a private
# `*_issue` method added to `issues`. Details stay data (negative positions,
# the open balance gap); UI::Account::HealthStatus formats them for the
# viewer's family.
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
    @issues ||= [ sync_issue, balance_gap_issue, negative_positions_issue ].compact
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

    # A gap between the balance the bank reports and the transaction history
    # while it is open (Balance::IntegrityChecker.open_gap_for). The link opens
    # the transactions since the last date both agreed.
    def balance_gap_issue
      gap = Balance::IntegrityChecker.open_gap_for(account)
      return unless gap

      Issue.new(
        severity: :warning,
        message: I18n.t("accounts.health_status.balance_gap.message"),
        details: [ gap ],
        hint: I18n.t("accounts.health_status.balance_gap.hint"),
        link: {
          text: I18n.t("accounts.health_status.balance_gap.link"),
          href: Rails.application.routes.url_helpers.transactions_path(q: { account_ids: [ account.id ], start_date: gap.anchor_waypoint.date })
        }
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
