class GocardlessItem::Importer
  attr_reader :gocardless_item, :client

  def initialize(gocardless_item, client:)
    @gocardless_item = gocardless_item
    @client          = client
  end

  def import
    unless gocardless_item.bank_connected?
      gocardless_item.update!(status: :requires_update)
      return { success: false, error: "Bank connection expired — please reconnect", accounts_updated: 0, transactions_imported: 0 }
    end

    accounts_updated      = 0
    accounts_failed       = 0
    transactions_imported = 0
    transactions_failed   = 0

    gocardless_item.gocardless_accounts.each do |gc_account|
      begin
        update_balance(gc_account)
        count = import_transactions(gc_account)
        transactions_imported += count
        accounts_updated += 1
      rescue Provider::Gocardless::AuthError
        gocardless_item.update!(status: :requires_update)
        accounts_failed += 1
        Rails.logger.error "GocardlessItem::Importer - Auth error for account #{gc_account.id}"
      rescue Provider::Gocardless::ApiError => e
        accounts_failed += 1
        Rails.logger.error "GocardlessItem::Importer - API error for account #{gc_account.id}: #{e.message}"
      rescue => e
        accounts_failed += 1
        Rails.logger.error "GocardlessItem::Importer - Unexpected error for account #{gc_account.id}: #{e.class} - #{e.message}"
      end
    end

    success = accounts_failed == 0 && transactions_failed == 0

    result = {
      success:              success,
      accounts_updated:     accounts_updated,
      accounts_failed:      accounts_failed,
      transactions_imported: transactions_imported,
      transactions_failed:  transactions_failed
    }

    result[:error] = "Some accounts failed to sync" unless success
    result
  end

  private

    def update_balance(gc_account)
      data     = client.balances(gc_account.account_id)
      balances = data["balances"] || []
      return if balances.empty?

      # Prefer interimAvailable, fall back to closingBooked, then first available
      bal = balances.find { |b| b["balanceType"] == "interimAvailable" } ||
            balances.find { |b| b["balanceType"] == "closingBooked" } ||
            balances.first

      return unless bal

      amount   = bal.dig("balanceAmount", "amount").to_d
      currency = bal.dig("balanceAmount", "currency") || gc_account.currency

      gc_account.update!(current_balance: amount, currency: currency)
    end

    def import_transactions(gc_account)
      start_date = determine_start_date(gc_account)
      data       = client.transactions(gc_account.account_id, date_from: start_date)
      booked     = data.dig("transactions", "booked") || []

      return 0 if booked.empty?

      existing_ids = existing_transaction_ids(gc_account)
      new_count    = 0

      booked.each do |txn|
        ext_id = txn["transactionId"] || txn["internalTransactionId"]
        next if ext_id.blank?
        next if existing_ids.include?(ext_id)

        create_transaction(gc_account, txn)
        new_count += 1
      rescue => e
        Rails.logger.error "GocardlessItem::Importer - Failed to import transaction #{ext_id}: #{e.message}"
      end

      # Store raw payload for reference
      gc_account.update!(raw_transactions_payload: booked)

      new_count
    end

    def create_transaction(gc_account, txn)
      account  = gc_account.account
      return unless account

      amount   = txn.dig("transactionAmount", "amount").to_d
      currency = txn.dig("transactionAmount", "currency") || gc_account.currency
      date     = parse_date(txn["bookingDate"] || txn["valueDate"])
      name     = extract_name(txn)
      ext_id   = txn["transactionId"] || txn["internalTransactionId"]

      account.entries.create!(
        name:        name,
        date:        date,
        amount:      amount,
        currency:    currency,
        entryable:   Transaction.new,
        import_id:   ext_id
      )
    end

    def extract_name(txn)
      txn["remittanceInformationUnstructured"] ||
        txn["remittanceInformationStructured"] ||
        txn["creditorName"] ||
        txn["debtorName"] ||
        "GoCardless transaction"
    end

    def determine_start_date(gc_account)
      has_transactions = gc_account.raw_transactions_payload.to_a.any?

      if has_transactions
        # Incremental — go back 7 days to catch late-settling transactions
        7.days.ago.to_date
      else
        # Initial sync — go back as far as GoCardless allows (730 days)
        gocardless_item.sync_start_date || 90.days.ago.to_date
      end
    end

    def existing_transaction_ids(gc_account)
      gc_account.account
                &.entries
                &.where.not(import_id: nil)
                &.pluck(:import_id)
                &.to_set || Set.new
    end

    def parse_date(date_str)
      return Date.current if date_str.blank?
      Date.parse(date_str.to_s)
    rescue ArgumentError
      Date.current
    end
end