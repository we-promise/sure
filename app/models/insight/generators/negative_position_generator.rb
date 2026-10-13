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
# position goes negative, its first date or the lowest quantity moves).
class Insight::Generators::NegativePositionGenerator < Insight::Generator
  produces "negative_position"

  MAX_INSIGHTS = 2

  def generate
    affected_accounts.lazy.filter_map do |account|
      positions = account.negative_positions
      next if positions.empty?

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
          lowest_qty: positions.map { |position| round(position.lowest_qty, 8) }
        },
        dedup_key: "negative_position:#{account.id}"
      )
    end.first(MAX_INSIGHTS)
  end

  private
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
      digits = ActiveSupport::NumberHelper.number_to_rounded(value.to_d.abs, precision: 8, strip_insignificant_zeros: true)
      value.negative? ? "−#{digits}" : digits
    end
end
