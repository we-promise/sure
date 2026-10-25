module Icost
  # Reconcile one owner's source archives under the existing family lock. Only
  # source-backed bookkeeping is recovered; unrelated ledger entries are kept.
  class Reconciler
    def initialize(user, import_id:, recover_all: false)
      @user = user
      @family = user.family
      @accounts = {}
      @import_id = import_id
      @recover_all = recover_all
    end

    def call
      IcostImport.authorize!(@family, @user)
      @family.with_lock do
        records = IcostRecord.owned_by(@user).includes(:icost_import, :entry, :counterpart_entry)
          .order("icost_imports.created_at", :source_row, :id).to_a
        @native_entries = @family.entries.where(account_id: writable_accounts.select(:id), entryable_type: "Transaction")
          .where("idempotency_key LIKE 'icost:%'").includes(:account, :entryable).to_a
        groups = group_occurrences(records)
        groups.each_value do |rows|
          next unless @recover_all || rows.any? { |record| record.icost_import_id == @import_id }
          canonical = rows.find(&:linked_entries_present?) || rows.first
          process(canonical)
          rows.reject { |record| record == canonical }.each { |record| mark_duplicate(record, canonical) }
        end
      end
    end

    private
      def writable_accounts
        @family.accounts.writable_by(@user).visible.manual
      end

      def group_occurrences(records)
        counts = Hash.new(0)
        @occurrences = {}
        records.each_with_object({}) do |record, groups|
          key = record.deduplication_key
          occurrence = counts[[ record.icost_import_id, key ]]
          counts[[ record.icost_import_id, key ]] += 1
          @occurrences[record.id] = occurrence
          (groups[[ key, occurrence ]] ||= []) << record
        end
      end

      def process(record)
        record.with_lock(requires_new: true) do
          # with_lock reloads the record, so set the checked fingerprint again.
          key = record.deduplication_key
          occurrence = @occurrences.fetch(record.id)
          record.resolution = record.resolution.except("duplicate_of_id", "duplicate_entry_id").merge(
            "deduplication_key" => key, "deduplication_occurrence" => occurrence)
          if record.linked_entries_present?
            record.update!(status: "published", issues: [], resolution: record.resolution)
            return
          end
          record.resolution["recovered_missing_entry"] = true if record.status == "published"
          if record.entry_id.present? || record.counterpart_entry_id.present?
            record.update!(status: "needs_review", issues: [ "transfer_link_incomplete" ])
            return
          end
          source = Icost::Normalizer.call(headers: record.icost_import.headers, values: record.source_values)
          issues = source.fetch(:issues)
          issues |= [ "currency_unsupported" ] unless Money::Currency.all.key?(record.currency.to_s.downcase)
          record.assign_attributes(status: "needs_review", issues: issues)
          currency_valid = (issues & %w[currency_invalid currency_unsupported]).empty?
          account = account_for(record) if currency_valid
          if %w[支出 收入].include?(record.transaction_type) && currency_valid
            if account
              record.save!
              record.resolve!(user: @user, attributes: { account_id: account.id })
            else
              record.issues |= [ record.account_name.blank? ? "account_required" : "account_ambiguous" ]
            end
          elsif record.transaction_type == "转账"
            # A supplied explicit transfer correction still has to pass all
            # normal account, currency and valuation checks.
            record.save!
            record.resolve!(user: @user, attributes: {})
          end
          candidates = source_entries(record)
          if candidates.any?
            if candidates.one? && matches_source?(candidates.first, record)
              record.update!(entry: candidates.first, status: "published", issues: [])
            else
              record.update!(status: "needs_review", issues: (record.issues + [ "existing_entry_mismatch" ]).uniq)
            end
            return
          end
          record.status = record.issues.empty? ? "ready" : "needs_review"
          record.save!
          record.publish!(user: @user) if record.status == "ready"
          @native_entries << record.entry if record.entry
        end
      rescue IcostRecord::ResolutionError, ActiveRecord::RecordInvalid => error
        review_error(record, error)
      rescue ActiveRecord::StatementInvalid => error
        # Isolate data/index constraints, but do not hide connection failures,
        # deadlocks or programming/schema errors as an invalid source row.
        state = error.cause.result&.error_field(PG::Result::PG_DIAG_SQLSTATE) if error.cause.respond_to?(:result)
        raise unless %w[22001 22003 23502 23505 23514 54000].include?(state)
        review_error(record, error)
      end

      def review_error(record, error)
        @accounts.clear
        record.reload
        record.update!(status: "needs_review", issues: (record.issues + [ "publication_validation_failed" ]).uniq)
        DebugLogEntry.capture(category: "import", level: "warn", source: self.class.name, provider_key: "icost",
          family: @family, message: "iCost row requires review", metadata: { icost_record_id: record.id, error_class: error.class.name })
      end

      def account_for(record)
        selected = writable_accounts.find_by(id: record.resolution["account_id"], currency: record.currency) if record.resolution["account_id"].present?
        return selected if selected
        known = source_entries(record)
        return known.first.account if known.one? && known.first.account.currency == record.currency
        name = record.account_name.to_s.strip
        return if name.empty? || !Money::Currency.all.key?(record.currency.to_s.downcase)
        @accounts.fetch([ name, record.currency ]) do |key|
          matches = writable_accounts.where(name: [ name, "iCost预览｜#{name}｜#{record.currency}｜期初未知" ], currency: record.currency).to_a
          @accounts[key] = if matches.one?
            matches.first
          elsif matches.empty?
            @family.accounts.create!(owner: @user, name: name, currency: record.currency, balance: 0, cash_balance: 0,
              accountable: Depository.new, notes: I18n.t("icost_imports.auto_account_note", locale: @user.locale.presence || I18n.default_locale))
          end
        end
      end

      def source_entries(record)
        @native_entries.select do |entry|
          metadata = entry.transaction.extra.fetch("icost", {})
          entry.idempotency_key == record.source_id ||
            (metadata["deduplication_key"] == record.resolution["deduplication_key"] &&
              metadata["deduplication_occurrence"] == record.resolution["deduplication_occurrence"])
        end.uniq(&:id)
      end

      def matches_source?(entry, record)
        %w[支出 收入].include?(record.transaction_type) && record.issues.empty? &&
          entry.date == record.ledger_date && entry.amount == -record.amount && entry.currency == record.currency &&
          entry.account.currency == record.currency && entry.account_id == record.resolution["account_id"] &&
          entry.transaction.kind == "standard" && !entry.transaction.transfer?
      end

      def mark_duplicate(record, canonical)
        if record.linked_entries_present?
          record.update!(status: "needs_review", issues: [ "existing_duplicate_entries" ],
            resolution: record.resolution.except("duplicate_of_id", "duplicate_entry_id"))
          return
        end
        if record.entry_id.present? || record.counterpart_entry_id.present?
          record.update!(status: "needs_review", issues: [ "transfer_link_incomplete" ],
            resolution: record.resolution.except("duplicate_of_id", "duplicate_entry_id"))
          return
        end
        record.update!(status: "needs_review", issues: [], resolution: record.resolution.merge(
          "duplicate_of_id" => canonical.id, "duplicate_entry_id" => canonical.entry_id,
          "deduplication_key" => record.deduplication_key, "deduplication_occurrence" => @occurrences.fetch(record.id)))
      end
  end
end
