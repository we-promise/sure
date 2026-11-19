# Flags investment accounts whose calculated position in a security went
# below zero. A sale entered by hand is refused before that can happen
# (Trade::SaleLimit), so this only fires for data that arrived another way:
# an import, a provider sync, or a deleted purchase. The holdings tab shows the
# same warning, but only to someone who opens that account; the feed is where
# a family notices it.
#
# One insight per account, naming the earliest position that went negative.
# The dedup key carries no month: missing data does not fix itself over time,
# so an acknowledged warning stays quiet until its numbers change (another
# position goes negative, or any position's first date or lowest quantity moves).
class Insight::Generators::NegativePositionGenerator < Insight::Generator
  produces "negative_position"

  MAX_INSIGHTS = 2

  # An acknowledged warning whose numbers have not changed gives its slot to
  # another account first, so dismissing two warnings does not hide a third.
  def generate
    fresh = []
    quiet = []

    affected_accounts.each do |account|
      insight = insight_for(account) or next
      (acknowledged_unchanged?(insight) ? quiet : fresh) << insight
      break if fresh.size >= MAX_INSIGHTS
    end

    (fresh + quiet).first(MAX_INSIGHTS)
  end

  private
    def insight_for(account)
      positions = account.negative_positions
      return if positions.empty?

      first = positions.first
      security = first.security

      build_insight(
        insight_type: "negative_position",
        priority: "medium",
        title: I18n.t("insights.titles.negative_position", account: account.name),
        template_key: "negative_position",
        facts: {
          account: account.name,
          security: security.name.presence || security.ticker,
          ticker: security.ticker,
          date: I18n.l(first.first_date, format: :long),
          qty: format_qty(first.lowest_qty),
          count: positions.size
        },
        metadata: {
          account_id: account.id,
          first_date: first.first_date.iso8601,
          security_ids: positions.map { |position| position.security.id },
          first_dates: positions.map { |position| position.first_date.iso8601 },
          lowest_qty: positions.map { |position| round(position.lowest_qty, 8) }
        },
        dedup_key: "negative_position:#{account.id}"
      )
    end

    def acknowledged_unchanged?(insight)
      @acknowledged_metadata ||= family.insights.acknowledged
        .where(insight_type: "negative_position").pluck(:dedup_key, :metadata).to_h
      @acknowledged_metadata[insight.dedup_key] == JSON.parse(insight.metadata.to_json)
    end

    # The feed is shared by the whole family and names the account and the
    # security, so only accounts every active member can see qualify. Ordered
    # so the pick stays stable between nightly runs.
    def affected_accounts
      family.accounts.visible.accessible_by_all_active_members
        .where(id: Holding.joins(:security).merge(Security.standard)
          .where(account_provider_id: nil).where("holdings.qty < 0").select(:account_id))
        .order(:name, :id)
    end

    # With a true minus sign, like the rest of the feed's display facts.
    def format_qty(value)
      digits = ActiveSupport::NumberHelper.number_to_rounded(value.to_d.abs, precision: 18, strip_insignificant_zeros: true)
      value.negative? ? "−#{digits}" : digits
    end
end
