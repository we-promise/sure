# Read-only diagnostic pass over an account's Valuation waypoints
# (opening_anchor, reconciliation, current_anchor). Does NOT run as part of
# the existing calculators — Balance::ReverseCalculator intentionally resets
# the balance to the bank-reported value at every reconciliation waypoint,
# neutralizing any drift from missing/duplicated transactions without
# recording the difference anywhere. This class is the only place in the
# system that surfaces that drift.
class Balance::IntegrityChecker
  TOLERANCE = 0.01.to_d
  MIN_DAYS_OPEN = 2 # a gap must persist longer than this before it's surfaced

  Waypoint = Data.define(:date, :value, :kind)
  # anchor_waypoint:     last waypoint where the ledger matched the reported balance
  # first_open_waypoint: the first waypoint AFTER the anchor where it stopped
  #                      matching — the date the discrepancy actually arose
  # latest_waypoint:     the most recent waypoint checked — defines current magnitude
  Gap = Data.define(:anchor_waypoint, :first_open_waypoint, :latest_waypoint, :implied_value, :actual_value, :difference)

  def initialize(account, tolerance: TOLERANCE, min_days_open: MIN_DAYS_OPEN)
    @account = account
    @tolerance = tolerance
    @min_days_open = min_days_open
  end

  # Can contain MULTIPLE entries per ongoing gap (one per waypoint while it
  # stays open) — not "one Gap per episode". latest_flagged_gap is what the
  # generator actually calls.
  def flagged_gaps
    # The walk starts from a snapshot it can trust exactly (see
    # exact_snapshot?), so no timing uncertainty is carried forward.
    wps = waypoints.drop_while { |wp| !exact_snapshot?(wp) }
    return [] if wps.size < 2

    gaps = []
    anchor = wps.first
    first_open_waypoint = nil
    open_residual = nil
    # Accumulated net flow since `anchor`, built up one (small, non-overlapping)
    # interval per iteration instead of re-summing the whole anchor..b range on
    # every step — while a gap stays open across many waypoints, that rescan
    # would otherwise cost O(waypoints) per waypoint.
    accumulated_flow = 0.to_d

    wps.each_cons(2) do |a, b|
      accumulated_flow += net_flow_between(a.date, b.date)
      implied = anchor.value + accumulated_flow
      # Residual is cumulative since the last point everything matched, not a
      # per-pair delta.
      residual = b.value - implied

      if residual.abs <= tolerance && exact_snapshot?(b)
        anchor = b
        first_open_waypoint = nil
        open_residual = nil
        accumulated_flow = 0.to_d
        next
      end

      # A busy day's snapshot that the day's own activity can explain says
      # nothing either way: it neither opens nor closes an episode, and the
      # anchor stays, so a gap smaller than the day's activity still shows on
      # the next exact snapshot. An episode already open keeps its start and
      # the residual last measured outside the timing range.
      if same_day_timing?(b, residual)
        next unless first_open_waypoint
      else
        first_open_waypoint ||= b
        # An exact snapshot measures the gap itself. On a busy day only the
        # part beyond the timing range is certain, so that is reported until
        # an exact snapshot settles it; either keeps the figure stable.
        if exact_snapshot?(b)
          open_residual = residual
        elsif open_residual.nil?
          open_residual = beyond_timing(b, residual)
        end
      end

      next unless (b.date - first_open_waypoint.date).to_i > min_days_open

      gaps << Gap.new(
        anchor_waypoint: anchor,
        first_open_waypoint: first_open_waypoint,
        latest_waypoint: b,
        implied_value: implied,
        actual_value: b.value,
        difference: open_residual
      )
    end

    gaps
  end

  # Only returns a Gap if the discrepancy is still open as of the most recent
  # waypoint. flagged_gaps keeps historical entries from episodes that have
  # since resolved — comparing against the true last waypoint is what makes
  # "already fixed" actually mean "already fixed" instead of resurfacing
  # forever.
  def latest_flagged_gap
    gaps = flagged_gaps
    return nil if gaps.empty?

    # gaps is built in wps traversal order, so the last entry is always the
    # most recent one — no need to re-derive that via max_by. Comparing the
    # whole Waypoint (not just its date) against the true last waypoint also
    # keeps this correct if two waypoints ever land on the same date (no DB
    # constraint enforces the model-level date-uniqueness validation, so a
    # concurrent write is a theoretical race, not an impossibility).
    last = gaps.last
    return nil unless last.latest_waypoint == waypoints.last
    last
  end

  private
    attr_reader :account, :tolerance, :min_days_open

    # account.valuations (has_many :valuations, through: :entries, source:
    # :entryable) returns bare Valuation records, but the valuations table
    # only has id/kind/timestamps — date/amount live on entries. Query
    # through Entry instead, joined to valuations only for the kind filter.
    #
    # Memoized: both flagged_gaps and latest_flagged_gap read this, and this
    # object is instantiated fresh per account per nightly run, so there's no
    # staleness concern within its lifetime.
    def waypoints
      @waypoints ||= account.entries
        .where(entryable_type: "Valuation")
        .preload(:entryable) # avoids one query per waypoint for e.entryable.kind below
        .joins("INNER JOIN valuations ON valuations.id = entries.entryable_id")
        .where(valuations: { kind: waypoint_kinds })
        .order(:date, :id) # secondary tiebreaker for waypoints sharing a date
        .map { |e| Waypoint.new(date: e.date, value: e.amount, kind: e.entryable.kind) }
    end

    # A linked account's reconciliation and current anchor hold the balance
    # the provider reported at that day's sync, not at the end of the day:
    # transactions dated that day but booked after the sync are in the ledger
    # and not in the snapshot, and pending ones may be in the snapshot but not
    # in the ledger. Which ones is unknown, so a snapshot is only exact on a
    # day without transactions. On a busy day the residual can be anything
    # from "every late or pending amount lowered the balance" to "every one
    # raised it". Manual valuations are end-of-day values.
    #
    # Transactions dated earlier but imported after a snapshot are no
    # concern: the import and the snapshot come from the same sync, so they
    # leave the most recent waypoint consistent.
    def exact_snapshot?(waypoint)
      !linked? || same_day_flows(waypoint.date).empty?
    end

    def same_day_timing?(waypoint, residual)
      return false unless linked?

      lowest, highest = timing_range(waypoint)
      residual.between?(lowest - tolerance, highest + tolerance)
    end

    def timing_range(waypoint)
      flows = same_day_flows(waypoint.date)
      [ flows.select(&:negative?).sum, flows.select(&:positive?).sum ]
    end

    # The part of a busy day's residual that its activity cannot explain.
    def beyond_timing(waypoint, residual)
      lowest, highest = timing_range(waypoint)
      residual.positive? ? residual - highest : residual - lowest
    end

    # Each amount's possible effect on the residual: a posted transaction
    # booked after the sync is missing from the snapshot (minus its flow), a
    # pending one may be in the snapshot but not in the ledger (plus its
    # flow). Signed like net_flow_between.
    def same_day_flows(date)
      @same_day_flows ||= {}
      @same_day_flows[date] ||= begin
        posted = sync_cache.get_entries(date).select(&:transaction?).map { |e| -flow(e.amount) }
        posted + pending_amounts_by_date.fetch(date, []).map { |amount| flow(amount) }
      end
    end

    def pending_amounts_by_date
      @pending_amounts_by_date ||= account.entries.pending.pluck(:date, :amount)
        .group_by(&:first).transform_values { |rows| rows.map(&:last) }
    end

    def flow(amount)
      account.asset? ? -amount : amount
    end

    def linked?
      return @linked if defined?(@linked)
      @linked = account.linked?
    end

    # A linked account's opening anchor is a placeholder, not a reported
    # balance: Account.create_and_sync writes the balance at link time, dated
    # before the imported history, and Balance::ReverseCalculator bridges it
    # with an opening-boundary adjustment instead of trusting it. Walking from
    # it would turn the whole imported history into a permanent "gap", so for
    # linked accounts the walk starts at the first provider-reported balance.
    def waypoint_kinds
      linked? ? %w[reconciliation current_anchor] : %w[opening_anchor reconciliation current_anchor]
    end

    # from_date is exclusive (flows *after* the anchor date), to_date inclusive.
    def net_flow_between(from_date, to_date)
      raw_sum = ((from_date + 1)..to_date).sum { |d| sync_cache.get_entries(d).select(&:transaction?).sum(&:amount) }
      account.asset? ? -raw_sum : raw_sum
    end

    def sync_cache
      @sync_cache ||= Balance::SyncCache.new(account)
    end
end
