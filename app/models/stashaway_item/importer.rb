# Fetches every StashAway portfolio with its transactions and daily values
# and stores them on its StashawayAccount: the one holding it, or for a
# portfolio not held yet the account of its name, funding source and goal
# type. Groups with nothing to import (closed or empty portfolios only) get
# no account until they do.
class StashawayItem::Importer
  STATE_ORDER = %w[ACTIVE ARCHIVED CLOSED].freeze

  attr_reader :stashaway_item, :provider

  def initialize(stashaway_item, provider:)
    @stashaway_item = stashaway_item
    @provider = provider
  end

  def import
    goals = provider.goals.select { |goal| goal.is_a?(Hash) && goal["_id"].present? }

    imported = assign(goals).count do |stashaway_account, account_goals|
      import_group(stashaway_account, sort_goals(account_goals))
    end

    { success: true, accounts: imported, goals: goals.size }
  end

  private

    # A portfolio stays with the account holding it (by its id, which the
    # account keeps), whatever it is named now, so a rename keeps the
    # account's link and history. A portfolio not held yet joins the oldest
    # account holding one of its name, funding source and goal type; failing
    # that, the oldest account opened for that key none of whose portfolios
    # StashAway lists any more; failing that, a new account. The accounts are
    # looked up outside the item's association: a new account for portfolios
    # that turn out to have nothing to import must not stay in the item's
    # unsaved records, where it would fail the item's next save. An account
    # none of whose portfolios StashAway lists any more is imported too, with
    # no listed portfolios, so it keeps its stored detail as unlisted and its
    # portfolios' disappearance is logged.
    def assign(goals)
      accounts = StashawayAccount.where(stashaway_item: stashaway_item).order(:created_at).to_a
      holder = {}
      accounts.each { |account| account.goal_ids.each { |id| holder[id] ||= account } }

      held, unheld = goals.partition { |goal| holder.key?(goal["_id"].to_s) }
      groups = held.group_by { |goal| holder[goal["_id"].to_s] }
      unheld.each do |goal|
        key = group_key(goal)
        account = accounts.find { |candidate| groups[candidate]&.any? { |other| group_key(other) == key } } ||
          accounts.find { |candidate| !groups.key?(candidate) && candidate.group_key == key } ||
          accounts.push(StashawayAccount.new(stashaway_item: stashaway_item, group_key: key)).last
        (groups[account] ||= []) << goal
      end
      accounts.each { |account| groups[account] ||= [] if account.persisted? && account.goal_ids.any? }
      groups
    end

    def group_key(goal)
      StashawayAccount.group_key_for(
        name: goal["displayName"],
        funding_source: goal["fundingSource"],
        goal_type: goal["goalType"],
        fallback: goal["_id"]
      )
    end

    def sort_goals(goals)
      goals.sort_by { |goal| [ STATE_ORDER.index(goal["state"]) || STATE_ORDER.size, goal["displayName"].to_s.strip ] }
    end

    # An account with no listed portfolio keeps its name, type and currency.
    def import_group(stashaway_account, goals)
      lead = goals.first
      currency = lead&.dig("currency").presence || stashaway_account.currency.presence || stashaway_item.family.currency
      value_currency = stashaway_account.current_account&.currency || currency
      stored = stashaway_account.goals.index_by { |goal| goal["id"] }

      records = goals.map { |goal| goal_record(goal, [ value_currency, currency ], stored, stashaway_account) }
      return false if stashaway_account.new_record? && records.none? { |record| importable?(record) }

      records += unlisted_records(stored, records, stashaway_account)

      plan = StashawayAccount::EntryPlan.new(goals: records, currency: currency).build
      # A plan with no usable value has no valuation to offer; the last one
      # stays for the setup and link dialogs while the new detail is stored.
      valuation = plan.applicable ? { current_balance: plan.final_nav, last_nav_date: plan.last_nav_date } : {}
      described = if lead
        {
          group_key: group_key(lead),
          name: lead["displayName"].to_s.strip.presence || I18n.t("stashaway_items.defaults.name"),
          goal_type: lead["goalType"],
          funding_source: lead["fundingSource"]
        }
      else
        {}
      end
      stashaway_account.update!(**described, currency: currency, raw_goals_payload: records, **valuation)
      true
    end

    def importable?(record)
      record["unavailable"].blank? && record["transactions"].any?
    end

    # What StashawayAccount::EntryPlan reads. StashAway serves no detail for
    # a closed portfolio, and may fail to serve one it still lists. Such a
    # portfolio keeps the detail stored for it last, marked unavailable, so
    # the account keeps its history; one never stored stays empty.
    def goal_record(goal, value_currencies, stored, stashaway_account)
      record = {
        "id" => goal["_id"].to_s,
        "name" => goal["displayName"].to_s.strip,
        "goal_type" => goal["goalType"],
        "funding_source" => goal["fundingSource"],
        "state" => goal["state"],
        "currency" => goal["currency"],
        "unavailable" => nil,
        "transactions" => [],
        "performance" => {}
      }
      return unavailable_record(record, stored, "closed") if goal["state"] == "CLOSED"

      record["transactions"] = provider.goal_transactions(record["id"])
      # Valued in the account's currency, the portfolio's own and each row's,
      # so a row in another currency converts at the portfolio's own rate.
      (value_currencies + transaction_currencies(record["transactions"])).compact.uniq.each do |value_currency|
        record["performance"][value_currency] = provider.goal_performance(record["id"], value_currency)
      end

      record
    rescue Provider::Stashaway::NotFound => e
      report_unavailable(record, e, stashaway_account)
      unavailable_record(record, stored, "not found")
    rescue Provider::Stashaway::ApiError => e
      # One portfolio's failure keeps its stored detail while the rest import.
      # A refused sign-in is an AuthenticationError, not an ApiError, and
      # still fails the sync.
      report_unavailable(record, e, stashaway_account)
      unavailable_record(record, stored, "error")
    end

    def unavailable_record(record, stored, reason)
      last = stored[record["id"]] || {}
      record.merge(
        "unavailable" => reason,
        "transactions" => Array(last["transactions"]),
        "performance" => last["performance"].is_a?(Hash) ? last["performance"] : {}
      )
    end

    # A portfolio the account holds that StashAway no longer lists keeps the
    # detail stored for it last, like one StashAway stops serving detail
    # for: dropping it would drop its rows and re-anchor the balance without
    # it. Its disappearance is logged once.
    def unlisted_records(stored, records, stashaway_account)
      listed = records.map { |record| record["id"] }
      stored.values.reject { |last| listed.include?(last["id"]) }.map do |last|
        report_unlisted(last, stashaway_account) unless last["unavailable"] == "unlisted"
        last.merge("unavailable" => "unlisted")
      end
    end

    def report_unlisted(record, stashaway_account)
      report_portfolio(record, stashaway_account,
        "StashAway no longer lists portfolio #{record["id"]} (#{record["name"]}); the detail stored for it last is used")
    end

    def report_unavailable(record, error, stashaway_account)
      report_portfolio(record, stashaway_account,
        "StashAway portfolio #{record["id"]} (#{record["name"]}): #{error.class} - #{error.message}; the detail stored for it last is used")
    end

    # Tied to the linked account when there is one, so the entry can be
    # traced to it.
    def report_portfolio(record, stashaway_account, message)
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: message,
        source: "stashaway",
        family: stashaway_item.family,
        account_provider: stashaway_account.account_provider,
        provider_key: "stashaway",
        metadata: { goal_id: record["id"], state: record["state"], stashaway_account_id: stashaway_account.id }
      )
    end

    def transaction_currencies(items)
      items.flat_map { |item| Array(item["transactions"]) }.filter_map { |row| row.dig("amount", "currency").presence }
    end
end
