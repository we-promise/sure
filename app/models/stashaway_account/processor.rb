# Brings the linked Sure account in line with its StashAway portfolios:
# creates and updates the planned entries by external id, removes StashAway
# entries the plan no longer has, and anchors the balance on StashAway's
# latest value. Entries from other sources are never touched, and a plan
# that is not applicable (see StashawayAccount::EntryPlan) changes nothing,
# apart from anchoring an account nothing was imported into yet on the last
# value stored for its portfolios, so that it does not show zero until a
# plan applies.
#
# Rows the user edited, excluded or import-locked stay as they are, and the
# plan counts them at their ledger figures. The one exception is a returns
# row ("ret:") the user only edited, say to categorize it: that row is
# Sure's own balancing figure, not user data, so its amount, date and name
# still follow the plan while the category, notes and tags stay.
class StashawayAccount::Processor
  Result = Data.define(:entries, :pending, :warnings)

  attr_reader :stashaway_account

  def initialize(stashaway_account)
    @stashaway_account = stashaway_account
  end

  def process
    return unless account

    plan = build_plan
    unless plan.applicable
      anchor_balance(stashaway_account.current_balance) if existing_entries.empty? && stashaway_account.current_balance
      return Result.new(entries: 0, pending: 0, warnings: plan.warnings)
    end

    Account.transaction do
      import_entries(plan.entries)
      remove_unplanned_entries(plan.entries)
      # The adapter builds each row into the account's entries before it
      # finds a statement copy to claim instead; the abandoned build stays
      # loaded, unsaved and invalid, and would fail the saves below.
      account.entries.reset
      anchor_balance(plan.expected_balance)
      account.ensure_opening_anchor_precedes_entries if start.nil?
    end

    account.broadcast_sync_complete
    Result.new(entries: plan.entries.size, pending: plan.pending.size, warnings: plan.warnings)
  end

  private

    def account
      @account ||= stashaway_account.current_account
    end

    def start
      stashaway_account.import_start_date
    end

    # The append base is fixed the first time it is known: the balances
    # after it are the import's own and would feed back into it.
    def build_plan
      base = StashawayAccount::ImportStart.new(stashaway_account, account).base_for(start)
      stashaway_account.update!(import_base: base) if start && base && stashaway_account.import_base.nil?

      StashawayAccount::EntryPlan.new(
        goals: stashaway_account.goals,
        currency: account.currency,
        start: start,
        base: base,
        protected: protected_entries
      ).build
    end

    def import_entries(entries)
      adapter = Account::ProviderImportAdapter.new(account)

      entries.each do |entry|
        existing = existing_entries[entry.external_id]
        if existing && returns_row_following_plan?(existing)
          existing.update!(amount: entry.amount, date: entry.date, name: entry.name)
          next
        end

        adapter.import_transaction(
          external_id: entry.external_id,
          amount: entry.amount,
          currency: account.currency,
          date: entry.date,
          name: entry.name,
          source: StashawayAccount::SOURCE,
          category_id: category_ids[entry.category&.downcase],
          # Reports count an investment account's labelled flows; a cash
          # account's rows are ordinary ones.
          investment_activity_label: account.investment? ? entry.activity_label : nil,
          extra: { StashawayAccount::SOURCE => { "kind" => entry.kind.to_s, "goal_id" => entry.goal_id }.compact },
          replace_extra_namespaces: [ StashawayAccount::SOURCE ],
          # Every planned row is dated on or after the import start, so a row
          # there of the same day and amount without an external id is a
          # statement copy of this one, claimed rather than duplicated.
          allow_heuristic_matching: true
        )
      end
    end

    # Rows the user edited or excluded stay, but a returns row that only
    # follows the plan goes with its month, as it would otherwise stand at a
    # figure the plan no longer has.
    #
    # Only rows from the import's start on are the plan's to remove: the
    # plan has none before it, and the StashAway rows there are history an
    # earlier link imported, as when an account is linked again after an
    # entry from another source was added.
    def remove_unplanned_entries(entries)
      planned_ids = entries.map(&:external_id)

      scope = account.entries
        .where(source: StashawayAccount::SOURCE)
        .where("entries.external_id IS NULL OR entries.external_id NOT IN (?)", planned_ids.presence || [ "" ])
      scope = scope.where("entries.date >= ?", start) if start
      scope.reject { |entry| entry.protected_from_sync? && !returns_row_following_plan?(entry) }.each(&:destroy!)
    end

    # Without waypoints: the history between month ends is the entries'
    # running balance, which reaches StashAway's value only where a returns
    # adjustment is booked.
    def anchor_balance(balance)
      account.update!(cash_balance: balance)
      result = account.set_current_balance(balance, schedule_sync: false, record_waypoint: false)
      raise Provider::Stashaway::Error, "Failed to set the current balance: #{result.error}" unless result.success?
    end

    # The account's StashAway rows by external id, as they are before this run.
    def existing_entries
      @existing_entries ||= account.entries.where(source: StashawayAccount::SOURCE).where.not(external_id: nil).index_by(&:external_id)
    end

    # The rows a sync leaves as they are, for the plan to count at their
    # ledger figures.
    def protected_entries
      existing_entries.values.filter_map do |entry|
        next unless entry.protected_from_sync? && !returns_row_following_plan?(entry)

        StashawayAccount::EntryPlan::ProtectedEntry.new(external_id: entry.external_id, date: entry.date, amount: entry.amount)
      end
    end

    # A returns row the user edited but neither excluded nor an import
    # locked: it takes the plan's amount, date and name directly. A row
    # without an external id is never one.
    def returns_row_following_plan?(entry)
      entry.external_id.to_s.start_with?("ret:") && entry.user_modified? && !entry.excluded? && !entry.import_locked?
    end

    # The family's own categories, matched by name.
    def category_ids
      @category_ids ||= account.family.categories
        .where("LOWER(name) IN (?)", StashawayAccount::EntryPlan::CATEGORY_NAMES.map(&:downcase))
        .pluck(:name, :id)
        .to_h { |name, id| [ name.downcase, id ] }
    end
end
