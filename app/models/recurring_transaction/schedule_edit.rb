class RecurringTransaction
  # Saves an edited series and reports what the save did to its occurrence
  # rows: the dates created, the open dates removed and the open dates
  # skipped. Regeneration stays in the series' own after_commit; this only
  # looks at the rows before and after it.
  #
  # dry_run runs the very same writes inside a savepoint that is always rolled
  # back, so the preview is the real code path rather than a re-derivation of
  # it that could drift. Nothing is committed. Only the schedule's effect on
  # occurrences is previewed: the history reconstruction that follows
  # confirming a suggestion is left out, since it can queue a job.
  #
  # skip_open_before_anchor closes, as skipped, the open rows already due
  # before a new anchor: the schedule they came from was replaced, and the
  # user said those dates are not owed. A row carrying any allocation is never
  # touched, and neither is anything due from today on, which regeneration
  # rebuilds anyway. Rows left open before the anchor are reported instead.
  class ScheduleEdit
    Report = Data.define(:created, :removed, :skipped, :left_open_before_anchor) do
      def to_h
        super.transform_values { |dates| dates.map(&:iso8601) }
      end
    end

    Row = Data.define(:due_on, :status)

    attr_reader :series, :anchor

    def initialize(series, anchor: nil, skip_open_before_anchor: false)
      @series = series
      @anchor = anchor
      @skip_open_before_anchor = skip_open_before_anchor && anchor.present?
    end

    # The Report, or nil when the series did not validate (its errors say why).
    def save(dry_run: false)
      before = snapshot
      saved = false
      preview = nil

      RecurringTransaction.transaction(requires_new: true) do
        # Ahead of the save: closing a row freezes its amount, and these dates
        # fell due at the price the series had before this edit.
        skip_open_rows_before_anchor if @skip_open_before_anchor

        saved = series.save
        raise ActiveRecord::Rollback unless saved

        if dry_run
          # A save that is rolled back never reaches after_commit, so the
          # preview runs the regeneration the commit would have triggered.
          series.regenerate_future_occurrences if series.schedule_shape_changed?
          preview = report(before, snapshot)
          raise ActiveRecord::Rollback
        end
      end

      return nil unless saved

      preview || report(before, snapshot)
    end

    private
      def occurrences
        # Not through the association: a loaded one would answer from memory.
        RecurringOccurrence.where(recurring_transaction_id: series.id)
      end

      def skip_open_rows_before_anchor
        occurrences.open_status
                   .where(due_on: ...[ anchor, Date.current ].min)
                   .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
                   .find_each(&:skip!)
      end

      def snapshot
        occurrences.pluck(:id, :due_on, :status).to_h { |id, due_on, status| [ id, Row.new(due_on:, status:) ] }
      end

      def report(before, after)
        removed = (before.keys - after.keys).map { |id| before[id].due_on }
        created = (after.keys - before.keys).map { |id| after[id].due_on }
        skipped = (before.keys & after.keys).select do |id|
          before[id].status == "scheduled" && after[id].status == "skipped"
        end
        left_open = anchor ? after.values.select { |row| row.status == "scheduled" && row.due_on < anchor } : []

        # Regeneration deletes the open future and inserts it again, so a date
        # the new schedule keeps comes back as a fresh row. That date did not
        # change.
        Report.new(
          created: without(created, removed).sort,
          removed: without(removed, created).sort,
          skipped: skipped.map { |id| after[id].due_on }.sort,
          left_open_before_anchor: left_open.map(&:due_on).sort
        )
      end

      # `dates` minus `others`, one for one, so two rows on a date and one
      # recreated still leave one.
      def without(dates, others)
        counts = others.tally

        dates.each_with_object([]) do |date, kept|
          if counts[date].to_i.positive?
            counts[date] -= 1
          else
            kept << date
          end
        end
      end
  end
end
