class GoalPledge::Reconciler
  attr_reader :entry

  # `valuation_delta` is the contribution (new_balance − prior_balance) for
  # Valuation entries, supplied by Account::ReconciliationManager which knows
  # the prior balance. It is ignored for Transaction entries, whose own
  # amount is already the contribution.
  def initialize(entry, valuation_delta: nil)
    @entry = entry
    @valuation_delta = valuation_delta
  end

  def run
    return unless eligible_entry?
    return if already_stamped?

    # Older pledges resolve first. Deterministic so "first claim wins"
    # under ties doesn't depend on PK ordering (which find_each batches
    # by) — relevant the day Sure adopts ULID/UUID PKs.
    GoalPledge
      .where(account_id: entry.account_id, status: "open", kind: expected_kind)
      .where("expires_at >= ?", Time.current)
      .order(:created_at, :id)
      .each do |pledge|
      next unless pledge.matches?(entry, valuation_delta: @valuation_delta)

      begin
        if entry.entryable.is_a?(Transaction)
          pledge.resolve_with!(entry.transaction)
        elsif entry.entryable.is_a?(Valuation)
          pledge.resolve_with_valuation!
        end
        Rails.logger.info("GoalPledge ##{pledge.id} matched entry ##{entry.id}")
        return
      rescue GoalPledge::NotOpenError,
             GoalPledge::AlreadyClaimedError,
             ActiveRecord::RecordInvalid,
             ActiveRecord::RecordNotUnique => e
        # Race vs another worker (this pledge got claimed, or this txn got
        # stamped by another pledge). Fall through and try the next pledge.
        Rails.logger.warn("GoalPledge ##{pledge.id} match failed: #{e.class}: #{e.message}")
      end
    end
  rescue StandardError => e
    # Don't let an unexpected reconcile failure break the importer pipeline
    # we're hooked into (ProviderImportAdapter / ReconciliationManager).
    # Surface to Sentry so the actual bug doesn't hide behind a warn-level
    # log; the inner narrow rescue handles known races without coming
    # through here.
    Rails.logger.error("GoalPledge::Reconciler failed for entry ##{entry&.id}: #{e.class}: #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  private
    def eligible_entry?
      return false if entry.account_id.blank?
      return false if entry.excluded?

      entry.entryable.is_a?(Transaction) || entry.entryable.is_a?(Valuation)
    end

    def already_stamped?
      return false unless entry.entryable.is_a?(Transaction)

      entry.transaction.extra.dig("goal", "pledge_id").present?
    end

    def expected_kind
      entry.entryable.is_a?(Valuation) ? "manual_save" : "transfer"
    end
end
