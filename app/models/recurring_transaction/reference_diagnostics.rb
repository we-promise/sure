class RecurringTransaction
  # Read-only "why is this payment not linked" report for a bill. A bill with a
  # bank reference is checked against every entry whose note carries it; any
  # other bill (a recurring transfer, say) against the entries on its account
  # with its amount. Each row gives the first reason the matcher would not (or
  # would) link the entry. Backs `rake recurring:diagnose_reference` and
  # `recurring:diagnose_series`; never writes.
  class ReferenceDiagnostics
    Row = Data.define(:entry_id, :date, :amount, :currency, :name, :verdict)

    # argument: a recurring transaction id, its name, or a bank reference text.
    def initialize(family, argument, months: 12)
      @family = family
      @argument = argument.to_s.strip
      @months = months.to_i
    end

    def rows
      matcher = Matcher.new(@family)

      entries.flat_map do |entry|
        series_list.map { |series| Row.new(entry_id: entry.id, date: entry.date, amount: entry.amount, currency: entry.currency,
                                           name: entry.name, verdict: "#{series.display_name}: #{verdict(matcher, series, entry)}") }
      end
    end

    def report
      rows.map do |row|
        format("%<date>s %<amount>10s %<currency>s  %<id>s  %<name>s -> %<verdict>s",
               date: row.date, amount: row.amount, currency: row.currency, id: row.entry_id, name: row.name.to_s.truncate(40), verdict: row.verdict)
      end.unshift("#{subject}: #{series_list.map(&:display_name).to_sentence} (#{entries.size} entries, last #{@months} months)")
    end

    private
      def series_list
        @series_list ||= begin
          needle = Matcher.normalize_name(@argument)
          found = if @argument.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
            @family.recurring_transactions.where(id: @argument).to_a
          else
            by_reference = @family.recurring_transactions.where.not("matcher_hints->>'bank_reference' IS NULL")
                                  .select { |series| Matcher.normalize_name(series.bank_reference) == needle }
            by_reference.presence || @family.recurring_transactions.select { |series| Matcher.normalize_name(series.display_name) == needle }
          end
          raise ArgumentError, "no bill with id, name or bank reference #{@argument.inspect}" if found.empty?

          found
        end
      end

      def references
        @references ||= series_list.filter_map { |series| Matcher.normalize_name(series.bank_reference.to_s).presence }.uniq
      end

      def reference
        @reference ||= references.first.to_s
      end

      def subject
        return "reference #{reference.inspect}" if reference.present?

        series = series_list.first
        "amount #{series.amount.abs} on #{series.account&.name || 'any account'}"
      end

      # Without a reference there is no note to look for: every entry on the
      # bill's account with the bill's amount is a payment it may have missed,
      # a recurring transfer's outflow included.
      def entries_by_amount
        series = series_list.first
        scope = @family.entries.where(entryable_type: "Transaction", excluded: false)
                       .where(date: @months.months.ago.to_date..Date.current)
                       .where("ABS(entries.amount) = ?", series.amount.abs)
                       .includes(:entryable)
        scope = scope.where(account_id: series.account_id) if series.account_id.present?
        scope.order(:date).to_a
      end

      def entries
        @entries ||= begin
          return entries_by_amount if reference.blank?

          patterns = references.map { |needle| "%#{Entry.sanitize_sql_like(needle).gsub(/\s+/, '%')}%" }
          scope = @family.entries.where(entryable_type: "Transaction")
                         .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
                         .where(date: @months.months.ago.to_date..Date.current)
          Matcher.with_note_patterns(scope, patterns)
                 .includes(:entryable)
                 .order(:date)
                 .to_a
        end
      end

      def verdict(matcher, series, entry)
        facts = matcher.diagnose(series, entry)
        allocations = RecurringAllocation.where(entry_id: entry.id).includes(recurring_occurrence: :recurring_transaction).to_a
        own = allocations.select { |allocation| allocation.recurring_occurrence.recurring_transaction_id == series.id }

        return "entry is excluded from tracking" if entry.excluded
        if (confirmed = own.find(&:allocation_confirmed?))
          return "linked (confirmed) to the cycle due #{confirmed.recurring_occurrence.due_on}"
        end
        if (other = allocations.find { |allocation| allocation.allocation_confirmed? && allocation.recurring_occurrence.recurring_transaction_id != series.id })
          return "already confirmed to another bill (#{other.recurring_occurrence.recurring_transaction.display_name})"
        end
        return "rejected by the user for this bill (never proposed again)" if RecurringMatchRejection.exists?(recurring_transaction_id: series.id, entry_id: entry.id)
        if series.transfer? && facts.currency_ok && facts.account_ok && facts.sign_ok
          return "not a transfer outflow (no transfer pair, kind #{entry.entryable.kind}); a recurring transfer is only paid by one" if facts.destination_id.nil?
          if facts.destination_id != series.destination_account_id
            return "wrong destination: the transfer pays into #{account_name(facts.destination_id)}, this series into #{account_name(series.destination_account_id)}"
          end
        end
        return "transfer leg (kind #{entry.entryable.kind}), not a candidate" if facts.transfer_kind || (entry.entryable.transfer? && !series.transfer?)
        return "wrong currency (#{entry.currency} vs #{series.currency})" unless facts.currency_ok
        return "wrong account" unless facts.account_ok
        return "wrong sign (bill is #{series.amount.positive? ? 'an expense' : 'income'})" unless facts.sign_ok
        return "reference not effective (income or account-less bill)" if series.bank_reference.present? && facts.reference.nil? && !facts.identity && (series.typed_income? || series.account_id.blank?)
        return "identity does not match (name/merchant/reference)" unless facts.identity
        return "this bill has ended: its cycles take no payments" if facts.nearest.nil? && series.ended?
        return "no occurrence to pair with" if facts.nearest.nil?
        return "reference payment more than a cycle before the first cycle: left alone" if facts.before_first_cycle
        unless facts.in_window || facts.reference
          return "outside the window of the nearest cycle (due #{facts.nearest.effective_due_on}, #{facts.nearest.status}; window #{facts.window.begin}..#{facts.window.end})"
        end
        return "another bill's reference in the note excludes this bill" if facts.confidence.to_f.zero?
        return "score #{facts.confidence.to_f.round(2)} below the suggestion threshold" if facts.confidence < Matcher::HIGH_TIER
        if facts.pending
          return "pending entry: only ever suggested, so skipped by the backfill"
        end

        rivals = competitors(matcher, series, entry, facts)
        return "another bill matches better (#{rivals[:stronger].to_sentence}), so it takes the payment, not this one" if rivals[:stronger].any?
        return "ambiguous with #{rivals[:ties].to_sentence} (tie, not auto-linked)" if rivals[:ties].any?

        tier = facts.confidence >= Matcher::EXACT_TIER ? "exact" : "suggestion"
        note = []
        note << "a suggested allocation exists (a confirmed link replaces it)" if own.any? || allocations.any?(&:allocation_suggested?)
        note << "cycle already paid: extra payment" if facts.nearest.paid?
        "would link (#{tier}, score #{facts.confidence.to_f.round(2)}) to the cycle due #{facts.nearest.effective_due_on}#{note.any? ? "; #{note.join('; ')}" : ''}"
      end

      def account_name(id)
        (@account_names ||= {})[id] ||= Account.find_by(id: id)&.name || "no account"
      end

      # Other bills that pair with the same entry about as well. A reference
      # match only ties with another reference match.
      def competitors(matcher, series, entry, facts)
        mine = facts.signals.to_h[:reference].present?

        rejected = RecurringMatchRejection.where(entry_id: entry.id).pluck(:recurring_transaction_id)
        result = { ties: [], stronger: [] }
        @family.recurring_transactions.where.not(status: "ended").where.not(id: [ series.id, *rejected ]).each do |other|
          theirs = matcher.diagnose(other, entry)
          next unless theirs.identity && (theirs.in_window || theirs.reference) && theirs.confidence.to_f >= Matcher::HIGH_TIER

          their_reference = theirs.signals.to_h[:reference].present?
          next if mine && !their_reference

          if !mine && their_reference || (theirs.confidence - facts.confidence) >= Matcher::AMBIGUITY_MARGIN
            result[:stronger] << other.display_name
          elsif (facts.confidence - theirs.confidence) < Matcher::AMBIGUITY_MARGIN
            result[:ties] << other.display_name
          end
        end
        result
      end
  end
end
