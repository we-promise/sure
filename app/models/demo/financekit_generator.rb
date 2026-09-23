class Demo::FinancekitGenerator
  ENROLLMENT_ID = "a332c972-621f-4d46-979a-559e9df26713".freeze
  CARD_SOURCE_ID = "a99206b4-c093-47dc-b8c2-de55ac12d273".freeze
  CASH_SOURCE_ID = "e2b91fd6-850c-457a-97ad-7c465070877a".freeze
  NANCY_SOURCE_ID = "7e784bc2-5b62-4b3e-84d6-8ec834128efa".freeze
  DAILY_CASH_RATE = BigDecimal("0.01") # Illustrative demo reward, not a live rate calculation.
  CARD_MERCHANTS = [ "Delta Airlines", "Hilton Hotels", "Expedia", "Apple", "BestBuy", "Amazon" ].freeze
  CASH_MERCHANTS = [ "Coffee Shop", "Corner Market", "Lunch", "Transit", "Farmers Market" ].freeze
  MERCHANT_CATEGORIES = {
    "Delta Airlines" => "Travel", "Hilton Hotels" => "Travel", "Expedia" => "Travel",
    "Apple" => "Shopping", "BestBuy" => "Shopping", "Amazon" => "Shopping",
    "Coffee Shop" => "Coffee & Takeout", "Corner Market" => "Groceries",
    "Lunch" => "Restaurants", "Transit" => "Transportation", "Farmers Market" => "Groceries"
  }.freeze
  FUNDING_ENTRIES = [ "Apple Card Payment", "Apple Cash Top Up" ].freeze

  def initialize(family, seed: 42)
    @family = family
    @rng = Random.new(seed.to_i)
  end

  # Additive and repeatable: never replace an existing Wallet enrollment or
  # clear a family's data. These synthetic records need no device or feature flags.
  def generate!
    @funding_accounts_to_sync = []
    item = @family.with_lock do
      existing = @family.financekit_items.find_by(enrollment_id: ENROLLMENT_ID)
      if existing
        @item = existing
        complete_demo_activity!
        generate_cash_family_activity!.each { |mapping| record_balance!(mapping) }
        next existing
      end

      user = @family.users.where(active: true, role: %w[admin super_admin]).order(:created_at).first!
      @item = Financekit::Enrollment.create!(user, {
        "enrollment_id" => ENROLLMENT_ID, "protocol_version" => Financekit::VERSION,
        "consent" => {
          "version" => 1, "granted_at" => Time.current.iso8601,
          "selected_source_account_ids" => [ CARD_SOURCE_ID, CASH_SOURCE_ID, NANCY_SOURCE_ID ],
          "upload_authorized" => true, "family_visibility_acknowledged" => true,
          "remote_processing_acknowledged" => true
        }
      }).item
      card = map_account!(CARD_SOURCE_ID, "Apple Card", "CreditCard", "credit_card")
      cash = map_account!(CASH_SOURCE_ID, "Apple Cash", "Depository", "cash")
      nancy = map_account!(NANCY_SOURCE_ID, "Nancy's Apple Cash", "Depository", "cash")
      @item.activate!
      generate_transactions!(card, cash)
      complete_demo_activity!
      generate_cash_family_activity!
      [ card, cash, nancy ].each { |mapping| record_balance!(mapping) }
      now = Time.current
      @item.update!(last_device_contact_at: now, last_accepted_at: now, last_imported_at: now)
      @item.syncs.create!(status: "completed", completed_at: now,
        sync_stats: { "total_accounts" => 3, "linked_accounts" => 3 })
      Financekit::Diagnostics.capture(item: @item, source: self.class.name,
        message: "FinanceKit demo accounts created", event: "demo_seeded", account_count: 3)
      @item
    end

    (item.accounts.to_a + @funding_accounts_to_sync).uniq.each { |account| Sync.create!(syncable: account).perform }
    item
  end

  private
    def map_account!(source_id, name, type, subtype)
      FinancekitAccount.map!(@item, source_id, {
        "expected_version" => 0, "action" => "create", "name" => name,
        "institution_name" => "Apple Wallet", "currency" => "USD",
        "accountable_type" => type, "subtype" => subtype,
        "ledger_timezone" => "America/Los_Angeles",
        "booked_balance" => { "amount" => "0.00", "currency" => "USD", "direction" => "credit" },
        "observed_at" => Time.current.iso8601
      })
    end

    def generate_transactions!(card, cash)
      month = 11.months.ago.to_date.beginning_of_month
      while month <= Date.current
        last_day = [ month.end_of_month, Date.current ].min
        total = 0
        @rng.rand(15..22).times do
          amount = @rng.rand(15..80)
          total += amount
          transaction!(card, amount, CARD_MERCHANTS.sample(random: @rng), @rng.rand(month..last_day))
        end
        transaction!(card, -(total * 0.92).round(2), "Apple Card Payment", last_day)

        transaction!(cash, -300, "Apple Cash Top Up", month)
        10.times do
          transaction!(cash, @rng.rand(5..25), CASH_MERCHANTS.sample(random: @rng), @rng.rand(month..last_day))
        end
        month = month.next_month
      end
      transaction!(card, 24.50, "Apple", Date.current, pending: true)
      transaction!(cash, 8.75, "Coffee Shop", Date.current, pending: true)
    end

    # Upgrade the old synthetic dataset in place, retaining account/entry IDs and
    # provider payloads. A marker preserves subsequent user edits on reruns.
    def complete_demo_activity!
      @item.financekit_accounts.where(source_id: [ CARD_SOURCE_ID, CASH_SOURCE_ID ]).each do |mapping|
        mapping.financekit_transactions.includes(entry: :entryable).each do |identity|
          entry = identity.entry
          next unless entry&.transaction? && entry.source == "financekit"

          transaction = entry.entryable
          next if transaction.extra["demo_financekit_activity_version"] == 1

          if (category_name = MERCHANT_CATEGORIES[entry.name]) && entry.amount.positive?
            if transaction.category.nil? || transaction.category.name == "Shopping"
              category = @family.categories.find_or_create_by!(name: category_name) do |record|
                record.lucide_icon = Category.suggested_icon(category_name)
              end
              transaction.update!(category: category)
            end
          elsif FUNDING_ENTRIES.include?(entry.name) && entry.amount.negative? && !transaction.pending?
            link_funding_transfer!(entry)
          else
            next
          end
          transaction.update!(extra: transaction.extra.merge("demo_financekit_activity_version" => 1))
        end
      end
    end

    def link_funding_transfer!(entry)
      inflow = entry.entryable
      unless inflow.transfer
        from = funding_account
        outflow = from.entries.create!(name: entry.name, date: entry.date, amount: -entry.amount,
          currency: entry.currency, entryable: Transaction.new(kind: Transfer.kind_for_account(entry.account)))
        Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow.entryable)
        @funding_accounts_to_sync << from
      end
      inflow.update!(kind: "funds_movement", category: nil)
    end

    def funding_account
      @funding_account ||= begin
        # Reuse the demo checking account, never add synthetic withdrawals to a
        # linked bank account or another household member's private account.
        checking = @family.accounts.manual.active.where(owner_id: @item.user_id,
          accountable_type: "Depository", currency: "USD", name: "Chase Premier Checking").first
        checking || @family.accounts.create!(name: "Wallet Demo Checking", owner: @item.user,
          currency: "USD", balance: 0, accountable: Depository.new(subtype: "checking")).tap do |account|
          entries = Entry.where(account_id: @item.accounts.select(:id))
          opening_balance = -entries.where("amount < 0").sum(:amount) + 5_000
          result = Account::OpeningBalanceManager.new(account).set_opening_balance(
            balance: opening_balance, date: entries.minimum(:date).prev_day)
          raise result.error unless result.success?
        end
      end
    end

    def generate_cash_family_activity!
      card = @item.financekit_accounts.find_by!(source_id: CARD_SOURCE_ID)
      cash = @item.financekit_accounts.find_by!(source_id: CASH_SOURCE_ID)
      nancy = @item.financekit_accounts.find_by(source_id: NANCY_SOURCE_ID)
      unless nancy
        # Only this synthetic enrollment is extended; real device enrollments
        # continue to manage their own consent and mapping lifecycle.
        @item.update!(status: "repair_required", consent: @item.consent.merge(
          "selected_source_account_ids" => (@item.consented_source_ids + [ NANCY_SOURCE_ID ]).uniq))
        nancy = map_account!(NANCY_SOURCE_ID, "Nancy's Apple Cash", "Depository", "cash")
        @item.activate!
      end

      changed = []
      today = Time.current.in_time_zone(cash.ledger_timezone).to_date
      daily_charges = card.financekit_transactions.where(status: "booked").joins(:entry)
        .where("entries.amount > 0 AND entries.date < ?", today).group("entries.date").sum("entries.amount")
      daily_charges.each do |date, total|
        source_id = Digest::UUID.uuid_v5(ENROLLMENT_ID, "daily-cash:#{date}")
        next if cash.financekit_transactions.exists?(source_id: source_id)

        reward = (total * DAILY_CASH_RATE).round(2)
        next unless reward.positive?

        identity = transaction!(cash, -reward, "Apple Card Daily Cash", date.next_day,
          source_id: source_id, transaction_type: "cashback")
        category = @family.categories.find_or_create_by!(name: "Cash Back")
        identity.entry.entryable.update!(category: category)
        changed << cash
      end

      # Six small gifts over the final weeks of the original demo history.
      # Stable source IDs keep later reruns from adding another six gifts.
      last_date = card.account.entries.maximum(:date)
      [ [ 35, 5 ], [ 28, 10 ], [ 21, 3 ], [ 14, 8 ], [ 7, 15 ], [ 2, 5 ] ].each_with_index do |(days, amount), index|
        sent_id = Digest::UUID.uuid_v5(ENROLLMENT_ID, "nancy-gift:#{index}:sent")
        next if cash.financekit_transactions.exists?(source_id: sent_id)

        received_id = Digest::UUID.uuid_v5(ENROLLMENT_ID, "nancy-gift:#{index}:received")
        sent = transaction!(cash, amount, "Sent to Nancy", last_date - days,
          source_id: sent_id, transaction_type: "transfer")
        received = transaction!(nancy, -amount, "Received from Dad", last_date - days,
          source_id: received_id, transaction_type: "transfer")
        [ sent, received ].each { |identity| identity.entry.entryable.update!(kind: "funds_movement") }
        Transfer.create!(outflow_transaction: sent.entry.entryable, inflow_transaction: received.entry.entryable)
        changed.concat([ cash, nancy ])
      end
      changed << nancy if generate_nancy_purchases!(nancy)
      changed.uniq
    end

    def generate_nancy_purchases!(nancy)
      # Spend a little of each gift the following day: a few outings per month,
      # all funded by the existing allowance rather than an overdraft.
      purchases = [
        [ "Candy Shop", "2.50", "Food & Dining" ],
        [ "Movie Theater", "8.00", "Entertainment" ],
        [ "After-School Snacks", "3.25", "Food & Dining" ],
        [ "Movie Theater", "9.00", "Entertainment" ],
        [ "Ice Cream Shop", "4.00", "Food & Dining" ],
        [ "Candy Shop", "1.75", "Food & Dining" ]
      ]
      changed = false
      purchases.each_with_index do |(name, amount, category_name), index|
        source_id = Digest::UUID.uuid_v5(ENROLLMENT_ID, "nancy-purchase:#{index}")
        next if nancy.financekit_transactions.exists?(source_id: source_id)

        gift_id = Digest::UUID.uuid_v5(ENROLLMENT_ID, "nancy-gift:#{index}:received")
        date = nancy.financekit_transactions.find_by!(source_id: gift_id).entry.date.next_day
        next if date > Time.current.in_time_zone(nancy.ledger_timezone).to_date

        identity = transaction!(nancy, amount.to_d, name, date, source_id: source_id)
        category = @family.categories.find_or_create_by!(name: category_name) do |record|
          record.lucide_icon = Category.suggested_icon(category_name)
        end
        identity.entry.entryable.update!(category: category)
        changed = true
      end
      changed
    end

    def transaction!(mapping, amount, name, date, pending: false, source_id: SecureRandom.uuid, transaction_type: nil)
      status = pending ? "pending" : "booked"
      transacted_at = [ date.in_time_zone(mapping.ledger_timezone).noon, Time.current ].min
      payload = {
        "source_id" => source_id, "source_account_id" => mapping.source_id,
        "lineage_id" => mapping.financekit_account_lineage_id, "mapping_version" => mapping.mapping_version,
        "status" => status, "transaction_type" => transaction_type || (amount.negative? ? "payment" : "purchase"),
        "transaction_description" => name, "original_transaction_description" => name,
        "transacted_at" => transacted_at.iso8601,
        "amount" => { "amount" => format("%.2f", amount.abs), "currency" => "USD",
                      "direction" => amount.negative? ? "credit" : "debit" }
      }
      payload["posted_at"] = transacted_at.iso8601 unless pending
      entry = mapping.account.entries.create!(name: name, date: transacted_at.in_time_zone(mapping.ledger_timezone).to_date, amount: amount, currency: "USD",
        source: "financekit", external_id: "financekit:#{mapping.financekit_account_lineage_id}:#{source_id}",
        entryable: Transaction.new(extra: { "financekit" => payload.merge("pending" => pending) }))
      mapping.financekit_transactions.create!(financekit_account: mapping, entry: entry, source_id: source_id,
        generation: @item.generation, sequence: 1, status: status, ledger_imported: true, raw_payload: payload)
    end

    def record_balance!(mapping)
      total = mapping.financekit_transactions.where(status: "booked").joins(:entry).sum("entries.amount")
      balance = mapping.accountable_type == "CreditCard" ? total : -total
      direction = mapping.accountable_type == "CreditCard" ? "debit" : "credit"
      mapping.financekit_balance_observations.create!(financekit_account: mapping, source_id: SecureRandom.uuid,
        kind: "booked", amount: balance, currency: "USD", direction: direction, observed_at: Time.current)
      Account::ProviderImportAdapter.new(mapping.account).update_balance(balance: balance, source: "financekit")
    end
end
