# frozen_string_literal: true

# StashAway goal records in the shape StashawayItem::Importer stores and
# StashawayAccount::EntryPlan reads.
module StashawayTestHelper
  # Daily value points from `from` to `to`, the value given by the block.
  def stashaway_daily(from, to)
    (Date.parse(from)..Date.parse(to)).map do |date|
      { "date" => "#{date.iso8601}T00:00:00.000Z", "amount" => yield(date.iso8601) }
    end
  end

  # One grouped StashAway transaction item holding one row.
  def stashaway_row(id, date, type, amount, currency = "SGD", description: type, code: nil, status: "Completed", operation_id: nil)
    {
      "id" => "g#{id}",
      "groupedDate" => date,
      "groupedType" => type,
      "groupedStatus" => status,
      "transactions" => [ {
        "id" => id,
        "transactionType" => type,
        "date" => date,
        "transactionStatus" => status,
        "amount" => { "amount" => amount, "currency" => currency },
        "description" => description,
        "metadata" => { "securityCode" => code, "operationId" => operation_id }
      } ]
    }
  end

  def stashaway_goal(id, transactions:, nav: {}, name: "General Investing", state: "ACTIVE", unavailable: nil)
    {
      "id" => id,
      "name" => name,
      "goal_type" => "CUSTOM",
      "funding_source" => "PERSONAL",
      "state" => state,
      "currency" => "SGD",
      "unavailable" => unavailable,
      "transactions" => transactions,
      "performance" => nav.transform_values { |points| { "nav" => points, "net_deposits" => [] } }
    }
  end

  def stashaway_plan(goals, currency: "SGD", start: nil, base: 0, protected: [])
    StashawayAccount::EntryPlan.new(goals: goals, currency: currency, start: start, base: base, protected: protected).build
  end

  # A StashAway row already in the account that a sync leaves as it is.
  def stashaway_protected(external_id, date, amount)
    StashawayAccount::EntryPlan::ProtectedEntry.new(external_id: external_id, date: Date.parse(date), amount: BigDecimal(amount.to_s))
  end

  # "date name amount" per entry, as the plan tests compare them.
  def stashaway_plan_lines(entries)
    entries.map { |entry| "#{entry.date.iso8601} #{entry.name} #{entry.amount.to_s("F").sub(/\.0\z/, "")}" }
  end
end
