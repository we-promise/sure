# Data-quality problems on one account, shown next to its sync state on the
# account page (#5162). Each source returns an Issue or nil; a new check adds
# its name to SOURCES and a `<name>_issue` method.
#
# Computed for the account the viewer opened, so it is only ever shown to
# someone who can see that account.
class Account::HealthStatus
  Issue = Data.define(:key, :severity, :message, :details, :hint, :link) do
    def initialize(key:, severity:, message:, details: [], hint: nil, link: nil)
      super
    end
  end

  SOURCES = %i[sync negative_positions].freeze

  attr_reader :account

  def initialize(account)
    @account = account
  end

  def issues
    @issues ||= SOURCES.filter_map { |source| send("#{source}_issue") }
  end

  private
    # The account's own latest sync: a later one that went through clears it.
    def sync_issue
      sync = account.latest_sync_record
      return unless sync&.failed? || sync&.stale?

      key = sync.failed? ? :sync_failed : :sync_stale
      Issue.new(
        key: key,
        severity: sync.failed? ? :error : :warning,
        message: I18n.t("accounts.health_status.#{key}.message"),
        hint: I18n.t("accounts.health_status.#{key}.hint")
      )
    end

    def negative_positions_issue
      positions = account.negative_positions
      return if positions.empty?

      Issue.new(
        key: :negative_positions,
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
