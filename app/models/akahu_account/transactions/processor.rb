class AkahuAccount::Transactions::Processor
  MAX_RECORDS = 20_000
  MAX_BYTES = 16.megabytes
  attr_reader :akahu_account

  def initialize(akahu_account, pending_inventory: nil, expected_context: nil)
    @akahu_account = akahu_account
    @pending_inventory = pending_inventory
    @expected_context = expected_context || AkahuItem::LegacyAccess.source_context(akahu_account)
  end

  def process
    AkahuItem::LegacyAccess.with_account(akahu_account) do |current|
      AkahuItem::LegacyAccess.verify_source!(current, @expected_context)
      self.class.new(current, pending_inventory: @pending_inventory, expected_context: @expected_context).send(:process_admitted)
    end
  end

  private
    def process_admitted
      stored = akahu_account.read_attribute_before_type_cast(:raw_transactions_payload)
      raise ArgumentError, "Akahu transaction cache exceeds its byte limit" if stored.to_json.bytesize > MAX_BYTES
      rows = akahu_account.raw_transactions_payload
      rows = [] if rows.nil?
      unless rows.is_a?(Array) && rows.size <= MAX_RECORDS
        raise ArgumentError, "Akahu transaction cache must be a bounded array"
      end
      imported_count, failed_count = 0, 0
      errors = []
      rows.each_with_index do |transaction_data, index|
        begin
          result = AkahuEntry::Processor.new(transaction_data, akahu_account: akahu_account,
            expected_context: @expected_context).process
          if result.nil?
            failed_count += 1
            errors << { index: index, error: "No linked account" }
          else
            imported_count += 1
          end
        rescue *AkahuItem::LegacyAccess::DENIAL_ERRORS
          raise
        rescue StandardError => error
          failed_count += 1
          errors << { index: index, error: I18n.t("akahu_item.errors.account_processing_failed") }
          report_failure(error, index)
        end
      end
      # A cache is not a fresh inventory. Even with a receipt, an incomplete
      # financial import cannot turn absence into deletion.
      pruned = if failed_count.zero? && @pending_inventory
        AkahuAccount::PendingCleanup.new(akahu_account, receipt: @pending_inventory).call
      else
        0
      end
      { success: failed_count.zero?, total: rows.size, imported: imported_count, failed: failed_count,
        pruned_pending: pruned, errors: errors }
    end

    def report_failure(error, index)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", source: self.class.name,
        provider_key: "akahu", family: akahu_account.akahu_item.family,
        message: "Akahu transaction publication failed; the row was rolled back",
        metadata: { akahu_account_id: akahu_account.id, index: index, error_class: error.class.name })
    rescue StandardError
      nil
    end
end
