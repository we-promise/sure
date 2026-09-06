class Assistant::Function::GetUncategorizedTransactions < Assistant::Function
  MAX_PAYEES = 50
  DEFAULT_LOOKBACK_DAYS = 180

  class << self
    def name
      "get_uncategorized_transactions"
    end

    def description
      <<~INSTRUCTIONS
        Lists the spending that has no category yet, grouped by payee rather than
        row by row.

        Use this before quoting any per-category total. A large uncategorized
        total means figures like "you spent X on restaurants" are understated by
        an unknown amount, and you should say so.

        Grouping is by the cleaned bank label, so "CB 02/09 CARREFOUR" and
        "CB 04/10 CARREFOUR" land in the same payee. Each group is what a single
        categorization rule would cover, so propose rules per payee instead of
        asking the user to classify individual transactions.

        The `enrichment` block explains WHY things are uncategorized. If it
        reports that no active rule performs auto-categorization, then nothing
        will ever categorize automatically no matter how long the user waits,
        and that is the finding to report first.

        Totals are reported per currency (`totals_by_currency`), never as one
        blended number, and each payee group carries its own currency.

        Transfers between the user's own accounts and excluded rows are never
        listed: they are not missing a category, they do not need one.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        start_date: {
          type: "string",
          description: "Start date, YYYY-MM-DD (defaults to #{DEFAULT_LOOKBACK_DAYS} days ago)"
        },
        end_date: {
          type: "string",
          description: "End date, YYYY-MM-DD (defaults to today)"
        },
        account_ids: {
          type: "array",
          items: { type: "string" },
          description: "Restrict to these account ids (from get_accounts)"
        },
        limit: {
          type: "integer",
          minimum: 1,
          maximum: MAX_PAYEES,
          description: "How many payee groups to return, largest total first (defaults to 20)"
        }
      }
    )
  end

  def call(params = {})
    period = resolve_period(params)
    limit = resolve_limit(params)

    entries = uncategorized_entries(period, params["account_ids"])
    groups = group_by_payee(entries)

    {
      as_of_date: Date.current,
      period: { start_date: period.first, end_date: period.last },
      summary: {
        transaction_count: entries.size,
        payee_count: groups.size,
        # Totals are per currency, never a single scalar. Summing a EUR row and
        # a USD row into one number and labelling it with the family currency
        # would be silently wrong, and this tool exists to make understatement
        # visible rather than to create more of it.
        totals_by_currency: totals_by_currency(entries)
      },
      payees: groups.first(limit).map { |group| serialize_group(group) },
      truncated: groups.size > limit,
      enrichment: enrichment_diagnostic
    }
  end

  private
    def resolve_period(params)
      start_date = parse_date(params["start_date"]) || DEFAULT_LOOKBACK_DAYS.days.ago.to_date
      end_date = parse_date(params["end_date"]) || Date.current
      start_date = end_date if start_date > end_date

      start_date..end_date
    end

    def parse_date(value)
      return nil if value.blank?
      Date.parse(value.to_s)
    rescue Date::Error
      nil
    end

    def resolve_limit(params)
      (Integer(params["limit"].to_s, exception: false) || 20).clamp(1, MAX_PAYEES)
    end

    # Entry.uncategorized_transactions already drops transfers and excluded
    # rows, and requires the caller to have scoped access first, which is what
    # accessible_accounts does here.
    def uncategorized_entries(period, account_ids)
      scope = Entry.where(account_id: accessible_account_ids(account_ids))
                   .uncategorized_transactions
                   .where(entries: { date: period })
                   # preload, not includes: the scope already carries a raw
                   # INNER JOIN on transactions, and `includes` would try to
                   # eager-load the polymorphic :entryable into that same query,
                   # which Rails refuses.
                   .preload(:account, entryable: :merchant)

      scope.to_a
    end

    def accessible_account_ids(requested)
      accessible = user.accessible_accounts.visible.pluck(:id)
      return accessible if requested.blank?

      accessible & Array(requested).map(&:to_s)
    end

    # Grouping on the cleaned label is the whole point: the raw label carries a
    # different date on every line, so grouping on `entries.name` would report
    # one payee per transaction and be useless for proposing rules.
    def group_by_payee(entries)
      entries
        .group_by { |entry| payee_key(entry) }
        .map do |(label, rail, currency), group|
          {
            label: label,
            rail: rail,
            currency: currency,
            entries: group,
            total: total_of(group)
          }
        end
        .sort_by { |group| -group[:total].abs }
    end

    # Currency is part of the key so a group's total is always expressible as
    # one Money. A payee billed in two currencies legitimately reads as two
    # rows, which is also what the user would want to see.
    def payee_key(entry)
      merchant = entry.entryable.merchant
      return [ merchant.name, nil, entry.currency ] if merchant

      label = Transaction::LabelNormalizer.normalize(entry.name, on: entry.date)
      [ label.name.upcase, label.rail, entry.currency ]
    end

    def totals_by_currency(entries)
      entries.group_by(&:currency).transform_values do |group|
        total = total_of(group)

        {
          amount: total,
          formatted: Money.new(total, group.first.currency).format,
          transaction_count: group.size
        }
      end
    end

    def serialize_group(group)
      entries = group[:entries]

      {
        payee: group[:label],
        rail: group[:rail],
        currency: group[:currency],
        transaction_count: entries.size,
        total_amount: group[:total],
        total_amount_formatted: Money.new(group[:total], group[:currency]).format,
        first_seen: entries.min_by(&:date).date,
        last_seen: entries.max_by(&:date).date,
        accounts: entries.map { |entry| entry.account.name }.uniq,
        # Enough ids to act on the group with update_transaction without
        # paging the whole thing back through get_transactions.
        transaction_ids: entries.first(10).map { |entry| entry.entryable_id }
      }.compact
    end

    def total_of(entries)
      entries.sum { |entry| entry.amount.to_d }
    end

    # Nothing in Sure categorizes or detects merchants on import. Both run only
    # as Rule actions (Rule::ActionExecutor::AutoCategorize and
    # ::AutoDetectMerchants), and `rules.active` defaults to false, so a family
    # that never built such a rule sees every transaction stay uncategorized
    # forever. The assistant cannot infer that from the data, so it is stated.
    def enrichment_diagnostic
      categorize = rule_state("auto_categorize")
      detect_merchants = rule_state("auto_detect_merchants")
      llm_configured = Provider::Registry.preferred_llm_provider.present?

      {
        auto_categorize_rule: categorize,
        auto_detect_merchants_rule: detect_merchants,
        llm_provider_configured: llm_configured,
        note: enrichment_note(categorize, detect_merchants, llm_configured)
      }
    end

    def rule_state(action_type)
      rules = family.rules.joins(:actions).where(rule_actions: { action_type: action_type })

      return "absent" if rules.empty?
      rules.where(active: true).any? ? "active" : "inactive"
    end

    def enrichment_note(categorize, detect_merchants, llm_configured)
      notes = []

      if categorize != "active"
        notes << "No active rule runs auto-categorization (state: #{categorize}), so nothing " \
                 "categorizes transactions automatically. The user creates one under Settings -> Rules."
      end

      if detect_merchants != "active"
        notes << "No active rule runs merchant detection (state: #{detect_merchants}), which is why " \
                 "`merchant` is null on most transactions."
      end

      notes << "No LLM provider is configured, so both actions would be no-ops even if a rule existed." unless llm_configured
      notes << "Automatic enrichment is configured and running." if notes.empty?

      notes.join(" ")
    end
end
