require "test_helper"

class WiseItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(
      family: @family,
      name: "Test Wise",
      token: "test_token",
      profile_id: "123",
      profile_type: :business
    )

    @standard_account = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000001",
      name: "Wise EUR",
      currency: "EUR",
      raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001 }
    )
    @standard_sure_account = Account.create!(
      family: @family,
      name: "Wise EUR",
      accountable: Depository.new(subtype: "checking"),
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: @standard_sure_account, provider: @standard_account)

    @jar_account = WiseAccount.create!(
      wise_item: @wise_item,
      balance_id: "10000002",
      name: "Jar",
      currency: "EUR",
      raw_payload: { "type" => "SAVINGS", "name" => "Jar" }
    )
    @jar_sure_account = Account.create!(
      family: @family,
      name: "Jar",
      accountable: Depository.new(subtype: "savings"),
      balance: 0,
      currency: "EUR"
    )
    AccountProvider.create!(account: @jar_sure_account, provider: @jar_account)
  end

  # SCA keypair

  test "sca_configured? is false without a private key" do
    assert_not @wise_item.sca_configured?
    assert_nil @wise_item.sca_public_key
  end

  test "sca_configured? is false when the stored private key is corrupted" do
    @wise_item.update_column(:sca_private_key, "not a real PEM")

    assert_nil @wise_item.sca_public_key
    assert_not @wise_item.sca_configured?
  end

  test "generate_sca_keypair! stores a private key and returns a matching public key" do
    stub_sca_encryption_available

    public_pem = @wise_item.generate_sca_keypair!

    assert @wise_item.sca_configured?
    assert_includes public_pem, "PUBLIC KEY"
    assert_equal public_pem, @wise_item.sca_public_key

    private_key = OpenSSL::PKey::RSA.new(@wise_item.sca_private_key)
    assert_equal private_key.public_key.to_pem, public_pem
  end

  test "refuses to store an SCA private key unless the attribute is registered encrypted" do
    WiseItem.stubs(:encryption_ready?).returns(true)
    WiseItem.stubs(:encrypted_attributes).returns([])

    assert_not @wise_item.sca_encryption_available?
    assert_raises(WiseItem::SCAEncryptionUnavailable) { @wise_item.generate_sca_keypair! }
    assert_nil @wise_item.reload.sca_private_key
  end

  test "refuses to store an SCA private key when encrypted attributes are unset" do
    WiseItem.stubs(:encryption_ready?).returns(true)
    WiseItem.stubs(:encrypted_attributes).returns(nil)

    assert_not @wise_item.sca_encryption_available?
    assert_raises(WiseItem::SCAEncryptionUnavailable) { @wise_item.generate_sca_keypair! }
    assert_nil @wise_item.reload.sca_private_key
  end

  # An SCA private key signs requests to Wise. Storing it unencrypted is not a
  # degraded mode worth having, so an install without Active Record encryption
  # is refused rather than silently writing the PEM in the clear.
  test "refuses to store an SCA private key when encryption is not configured" do
    WiseItem.stubs(:encryption_ready?).returns(false)

    assert_raises(WiseItem::SCAEncryptionUnavailable) { @wise_item.generate_sca_keypair! }
    assert_nil @wise_item.reload.sca_private_key

    @wise_item.sca_private_key = "not a real PEM"

    assert_not @wise_item.valid?
    assert_includes @wise_item.errors.attribute_names, :sca_private_key
  end

  # The validation guards writes of the key, not the record. A value stored
  # before it existed must not make the record permanently unsaveable: the
  # destroy path unlinks the accounts first and only then calls update!, so a
  # refusal there strands the provider half unlinked and still active.
  test "a key stored before encryption was required does not block later saves" do
    WiseItem.stubs(:encryption_ready?).returns(false)
    @wise_item.update_column(:sca_private_key, "legacy plaintext value")

    assert @wise_item.reload.valid?
    assert @wise_item.update(name: "Renamed connection")

    assert_nothing_raised { @wise_item.destroy_later }
    assert @wise_item.reload.scheduled_for_deletion
  end

  # Same shape as the other Encryptable models' tests: the suite deliberately
  # runs without encryption keys (see EncryptionVerificationTest), so this
  # skips rather than asserting a state the default environment cannot reach.
  test "declares the SCA private key as encrypted" do
    skip "Encryption not configured" unless WiseItem.encryption_ready?

    assert_includes WiseItem.encrypted_attributes.map(&:to_s), "sca_private_key"
  end

  test "generate_sca_keypair! replaces a previously generated key" do
    stub_sca_encryption_available

    first_public_key = @wise_item.generate_sca_keypair!
    second_public_key = @wise_item.generate_sca_keypair!

    assert_not_equal first_public_key, second_public_key
  end

  # Sync metadata (raw_payload)

  test "sync metadata reads a blank raw_payload and merges writes" do
    assert_equal({}, @wise_item.sync_metadata)
    assert_nil @wise_item.fetch_coverage(:transfers)

    @wise_item.merge_sync_metadata!(coverage: { "transfers" => { "from" => "2025-04-02T16:00:00Z", "through" => "2026-10-17T12:00:00Z",
                                                                 "version" => WiseItem::COVERAGE_VERSION } })
    @wise_item.merge_sync_metadata!("multi_currency_account" => { "recipientId" => 99999001 })

    assert_equal %w[coverage multi_currency_account], @wise_item.reload.raw_payload.keys.sort
    assert_equal({ from: Time.utc(2025, 4, 2, 16), through: Time.utc(2026, 10, 17, 12) }, @wise_item.fetch_coverage("transfers"))
    assert_nil @wise_item.fetch_coverage(:activities)
  end

  # Coverage an older build recorded claims rows that build did not keep, so
  # it counts as none.
  test "fetch coverage ignores coverage recorded under an older coverage version" do
    window = { "from" => "2025-08-27T03:00:00Z", "through" => "2026-10-17T12:00:00Z" }
    @wise_item.merge_sync_metadata!(coverage: { "transfers" => window, "activities" => window.merge("version" => WiseItem::COVERAGE_VERSION - 1) })
    assert_nil @wise_item.fetch_coverage(:transfers)
    assert_nil @wise_item.fetch_coverage(:activities)

    @wise_item.merge_sync_metadata!(coverage: { "transfers" => window.merge("version" => WiseItem::COVERAGE_VERSION + 1) })
    assert_equal({ from: Time.utc(2025, 8, 27, 3), through: Time.utc(2026, 10, 17, 12) }, @wise_item.fetch_coverage(:transfers))
  end

  # Family checks its zone only when it changes, so a zone stored before that
  # check (or one tzdata dropped later) can stay. Every Wise row then failed
  # on it; now Wise dates fall back to UTC, reported once a day rather than on
  # every sync of every balance.
  test "time zone falls back to UTC for a family zone tzdata does not know, reported once a day" do
    original_cache = Rails.cache
    # The test store (:null_store) keeps nothing, so the once-a-day lease
    # needs a real one.
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @family.update_column(:timezone, "Invalid/Timezone")
    notes = -> { DebugLogEntry.where(provider_key: "wise").where("metadata ->> 'operation' = ?", "time_zone") }

    assert_difference -> { notes.call.count }, 1 do
      2.times { assert_equal ActiveSupport::TimeZone["UTC"], WiseItem.find(@wise_item.id).time_zone }
    end
    assert_equal [ "warn", @family ], notes.call.sole.then { |note| [ note.level, note.family ] }

    @family.update_column(:timezone, "Europe/Dublin")
    assert_equal ActiveSupport::TimeZone["Europe/Dublin"], WiseItem.find(@wise_item.id).time_zone
    @family.update_column(:timezone, nil)
    assert_equal ActiveSupport::TimeZone["UTC"], WiseItem.find(@wise_item.id).time_zone
  ensure
    Rails.cache = original_cache
  end

  test "own_recipient_ids holds the account recipient and every balance's own recipient" do
    @wise_item.merge_sync_metadata!("multi_currency_account" => { "recipientId" => 99999009 })
    @standard_account.update!(raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001, "recipientId" => 77777001 })
    WiseAccount.create!(wise_item: @wise_item, balance_id: "10000003", name: "Wise USD", currency: "USD",
                        raw_payload: { "type" => "STANDARD", "recipient_id" => 99999001, "recipientId" => 77777003,
                                       "closed_at" => "2026-09-01T00:00:00Z" })

    assert_equal %w[99999009 99999001 77777001 77777003].sort, @wise_item.own_recipient_ids.sort
  end

  # Each balance's processing asks for the recipients, so reading every
  # balance's stored rows (the whole history) for them would grow with the
  # square of the balances.
  test "reads the recipients without loading any balance's stored rows" do
    @standard_account.update!(raw_payload: { "type" => "STANDARD", "recipientId" => 77777001 },
                              raw_transactions_payload: [ { "id" => 1 } ])
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("wise_accounts") }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      assert_includes WiseItem.find(@wise_item.id).own_recipient_ids, "77777001"
      assert_equal({ "77777001" => [ @standard_account.id ] }, WiseItem.find(@wise_item.id).balance_recipient_owners)
    end

    assert_equal 2, queries.size
    queries.each { |sql| assert_no_match(/raw_transactions_payload|wise_accounts"\.\*/, sql) }
  end

  # Whether the import re-fetched the whole history no longer travels with it:
  # the balances whose rows that moved keep it themselves
  # (WiseAccount#prune_cap_bypass_ids).
  test "process_accounts tells each account processor whether the import was complete" do
    WiseAccount::Processor.expects(:new).with(@standard_account, import_complete: true).returns(stub(process: { imported: 0 }))
    WiseAccount::Processor.expects(:new).with(@jar_account, import_complete: true).returns(stub(process: { imported: 0 }))

    results = @wise_item.process_accounts(import_complete: true)

    assert_equal [ true, true ], results.map { |result| result[:success] }
  end

  test "process_accounts assumes an incomplete import unless told otherwise" do
    WiseAccount::Processor.expects(:new).twice
                          .with { |_wise_account, options| options == { import_complete: false } }
                          .returns(stub(process: nil))

    @wise_item.process_accounts
  end

  # link_jar_transfers!
  #
  # Legs are booked through WiseActivity::Processor, as a sync books them, so
  # they start out as standard transactions. These tests used to build the legs
  # by hand as funds_movement, which hid that linking never set any kinds.

  test "links matching interbalance inflow and outflow entries as a Transfer" do
    inflow, outflow = book(jar_deposit("5001", "1,000 EUR"), @jar_account, @standard_account)

    assert_difference "Transfer.count", 1 do
      @wise_item.link_jar_transfers!
    end

    transfer = Transfer.find_by!(inflow_transaction_id: inflow.entryable_id)
    assert_equal outflow.entryable_id, transfer.outflow_transaction_id
    assert transfer.confirmed?
    assert_equal %w[funds_movement funds_movement], leg_kinds(inflow, outflow)
  end

  test "does not create duplicate Transfer for already-linked pair" do
    book(jar_deposit("5002", "2,000 EUR"), @jar_account, @standard_account)

    @wise_item.link_jar_transfers!

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end
  end

  test "skips unmatched inflow entries with no corresponding outflow" do
    book(jar_deposit("5003", "500 EUR"), @jar_account)

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end
  end

  test "links multiple interbalance pairs in one call" do
    book(jar_deposit("6001", "1,000 EUR"), @jar_account, @standard_account)
    book(jar_deposit("6002", "3,000 EUR"), @jar_account, @standard_account)

    assert_difference "Transfer.count", 2 do
      @wise_item.link_jar_transfers!
    end
  end

  test "does nothing when no interbalance entries exist" do
    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end
  end

  # Without transfer kinds, reports counted every conversion as income on one
  # balance and spending on the other.
  test "a linked conversion counts as neither income nor spending" do
    inflow, outflow = book(gbp_to_eur("9000000106"), @standard_account, create_balance("GBP", "10000003"))

    @wise_item.link_jar_transfers!

    assert Transfer.find_by!(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id).confirmed?
    assert_equal %w[funds_movement funds_movement], leg_kinds(inflow, outflow)
  end

  test "repairs a conversion linked before its legs got transfer kinds" do
    inflow, outflow = book(gbp_to_eur("9000000106"), @standard_account, create_balance("GBP", "10000003"))
    # What earlier versions saved: a confirmed transfer with both legs standard.
    transfer = Transfer.create!(inflow_transaction: inflow.entryable, outflow_transaction: outflow.entryable, status: "confirmed")

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end

    assert transfer.reload.confirmed?
    assert_equal %w[funds_movement funds_movement], leg_kinds(inflow, outflow)
  end

  # An older build read this withdrawal from a jar Wise named like its
  # currency as a deposit, booked its legs on the wrong sides and linked them
  # that way round. The legs are renamed to their sides (and re-signed), and
  # the reversed link is replaced, so the withdrawal is no income and no
  # spending.
  test "replaces a link an older build made the wrong way round" do
    @jar_account.update!(name: "EUR", raw_payload: { "type" => "SAVINGS", "name" => "EUR" })
    withdrawal = interbalance("5501", title: "To <strong>EUR</strong>", primary: "500 EUR")
    jar_leg = leg(@jar_account, "5501_inflow", -500)
    balance_leg = leg(@standard_account, "5501_outflow", 500)
    Transfer.create!(inflow_transaction: jar_leg.entryable, outflow_transaction: balance_leg.entryable, status: "confirmed")
    [ @jar_account, @standard_account ].each do |wise_account|
      wise_account.update!(raw_transactions_payload: [ withdrawal ])
      WiseAccount::Transactions::Processor.new(wise_account.reload, import_complete: true).process
    end

    stats = @wise_item.link_jar_transfers!

    transfer = Transfer.where(inflow_transaction_id: [ balance_leg.entryable_id, jar_leg.entryable_id ]).sole
    assert_equal [ balance_leg.entryable_id, jar_leg.entryable_id ], [ transfer.inflow_transaction_id, transfer.outflow_transaction_id ]
    assert_equal [ "wise_interbalance_5501_inflow", BigDecimal("-500") ], balance_leg.reload.values_at(:external_id, :amount)
    assert transfer.confirmed? && transfer.valid?
    assert_equal %w[funds_movement funds_movement], leg_kinds(balance_leg, jar_leg)
    assert_equal 1, stats[:replaced_stale_links]
  end

  # Removing a link the linker made (the transfer drawer's Delete) records a
  # rejection, so the next sync does not link the legs again.
  test "a link the linker makes again on its own is told apart from a person's transfer" do
    inflow, outflow = book(gbp_to_eur("9000000106"), @standard_account, create_balance("GBP", "10000003"))
    @wise_item.link_jar_transfers!
    linked = Transfer.find_by!(inflow_transaction_id: inflow.entryable_id)
    bank = bank_entry(amount: 50, date: Date.current)
    person = Transfer.create!(inflow_transaction: @standard_sure_account.entries.create!(amount: -50, currency: "EUR", date: Date.current,
                                                                                         name: "From bank", entryable: Transaction.new).entryable,
                              outflow_transaction: bank.entryable, status: "confirmed")

    assert WiseItem::InterbalanceLinker.relinks?(linked)
    assert_not WiseItem::InterbalanceLinker.relinks?(person)
    linked.update!(notes: "Moved my savings")
    assert_not WiseItem::InterbalanceLinker.relinks?(linked)
  end

  # A transfer from the GBP balance into the euro balance's own account
  # details is in both statements under its reference: a debit on GBP and a
  # credit on EUR, linked as a transfer like a conversion. A refund credit
  # shares the reference on the paying balance and is left alone.
  test "links the two statement rows of a send from one balance to another's account details" do
    gbp = create_balance("GBP", "10000003")
    debit = statement_entry(gbp, "wise_statement_TRANSFER-4242", 100)
    statement_entry(gbp, "wise_statement_TRANSFER-4242_fee", 0.5)
    credit = statement_entry(@standard_account, "wise_statement_TRANSFER-4242", -115)
    refunded = statement_entry(gbp, "wise_statement_TRANSFER-4343", 40)
    statement_entry(gbp, "wise_statement_TRANSFER-4343_CREDIT_20260303", -40)

    @wise_item.link_jar_transfers!

    transfer = Transfer.where(outflow_transaction_id: gbp.current_account.transactions.select(:id)).sole
    assert_equal [ credit.entryable_id, debit.entryable_id ], [ transfer.inflow_transaction_id, transfer.outflow_transaction_id ]
    assert transfer.confirmed?
    assert WiseItem::InterbalanceLinker.relinks?(transfer)
    assert_equal "standard", refunded.entryable.reload.kind
  end

  test "does not relink a conversion the user rejected" do
    inflow, outflow = book(gbp_to_eur("9000000106"), @standard_account, create_balance("GBP", "10000003"))
    @wise_item.link_jar_transfers!
    Transfer.find_by!(inflow_transaction_id: inflow.entryable_id).reject!

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end

    assert RejectedTransfer.exists?(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id)
    assert_equal %w[standard standard], leg_kinds(inflow, outflow)
  end

  test "replaces a pending suggestion that holds one conversion leg" do
    inflow, outflow = book(gbp_to_eur("9000000106"), @standard_account, create_balance("GBP", "10000003"))
    bank_credit = bank_entry(amount: -1180, date: outflow.date)
    suggestion = Transfer.create!(inflow_transaction: bank_credit.entryable, outflow_transaction: outflow.entryable, status: "pending")

    @wise_item.link_jar_transfers!

    assert_not Transfer.exists?(suggestion.id)
    assert Transfer.find_by!(inflow_transaction_id: inflow.entryable_id, outflow_transaction_id: outflow.entryable_id).confirmed?
    assert_equal "standard", bank_credit.entryable.reload.kind
  end

  test "confirms a pending suggestion that already pairs the two legs" do
    inflow, outflow = book(jar_deposit("5004", "250 EUR"), @jar_account, @standard_account)
    suggestion = Transfer.create!(inflow_transaction: inflow.entryable, outflow_transaction: outflow.entryable, status: "pending")

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end

    assert suggestion.reload.confirmed?
    assert_equal %w[funds_movement funds_movement], leg_kinds(inflow, outflow)
  end

  test "keeps the suggestion when the conversion cannot be linked" do
    inflow, outflow = book(gbp_to_eur("9000000106"), @standard_account, create_balance("GBP", "10000003"))
    # A confirmed transfer allows at most 30 days between its legs.
    outflow.update_columns(date: inflow.date - 31.days)
    bank_debit = bank_entry(amount: 1234.56, date: inflow.date)
    suggestion = Transfer.create!(inflow_transaction: inflow.entryable, outflow_transaction: bank_debit.entryable, status: "pending")

    assert_difference "DebugLogEntry.count", 1 do
      @wise_item.link_jar_transfers!
    end

    assert Transfer.find(suggestion.id).pending?, "a refused link must not take the suggestion with it"
    assert_not Transfer.exists?(outflow_transaction_id: outflow.entryable_id)
  end

  test "leaves a conversion leg the user confirmed against another transaction" do
    inflow, outflow = book(gbp_to_eur("9000000106"), @standard_account, create_balance("GBP", "10000003"))
    bank_debit = bank_entry(amount: 1234.56, date: inflow.date)
    users_link = Transfer.create!(inflow_transaction: inflow.entryable, outflow_transaction: bank_debit.entryable, status: "confirmed")

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end

    assert Transfer.exists?(users_link.id)
    assert_not Transfer.exists?(outflow_transaction_id: outflow.entryable_id)
  end

  # Before conversions were routed by currency, every STANDARD balance booked
  # an _outflow copy of each one in the target currency, the target balance
  # included, and upgraded installs still hold those entries.
  test "links the leg on the conversion's source balance when earlier routing left copies" do
    usd = create_balance("USD", "10000004")
    inflow, outflow = book(gbp_to_eur("9000000106"), @standard_account, create_balance("GBP", "10000003"))
    [ @standard_account, usd ].each { |wise_account| book_pre_routing_copy(wise_account, "9000000106", inflow.date) }

    @wise_item.link_jar_transfers!

    assert_equal outflow.entryable_id, Transfer.find_by!(inflow_transaction_id: inflow.entryable_id).outflow_transaction_id
  end

  test "does not link a copy on a balance in another currency than the conversion's source" do
    inflow, = book(gbp_to_eur("9000000106"), @standard_account) # Wise GBP is not linked in Sure
    book_pre_routing_copy(create_balance("USD", "10000004"), "9000000106", inflow.date)

    assert_difference "DebugLogEntry.count", 1 do
      @wise_item.link_jar_transfers!
    end

    assert_not Transfer.exists?(inflow_transaction_id: inflow.entryable_id)
  end

  # Wise's automatic conversions (e.g. for a card payment in a currency the
  # balance lacks) are booked through the conversion path, and their stored
  # rows name the source balance just as INTERBALANCE rows do.
  test "links an auto-conversion on its source balance like a conversion" do
    auto_conversion = gbp_to_eur("9000000107").merge("type" => "AUTO_CONVERSION", "id" => "auto_conversion_9000000107")
    inflow, outflow = book(auto_conversion, @standard_account, create_balance("GBP", "10000003"))
    book_pre_routing_copy(create_balance("USD", "10000004"), "9000000107", inflow.date)

    @wise_item.link_jar_transfers!

    transfer = Transfer.find_by!(inflow_transaction_id: inflow.entryable_id)
    assert_equal outflow.entryable_id, transfer.outflow_transaction_id
    assert transfer.confirmed?
    assert_equal %w[funds_movement funds_movement], leg_kinds(inflow, outflow)
  end

  # The linker before routing by currency confirmed a jar move's leg against
  # whichever _outflow copy it found first, usually one routing had booked on
  # another balance in the move's currency. That link is the linker's own, not
  # a person's, so the move's real legs replace it.
  test "replaces a link the old linker made to a copy earlier routing left on another balance" do
    jar_leg, eur_leg = book(jar_deposit("5005", "100 EUR"), @jar_account, @standard_account)
    copy = book_pre_routing_copy(create_balance("GBP", "10000003"), "5005", jar_leg.date, amount: 100)
    old_link = Transfer.create!(inflow_transaction: jar_leg.entryable, outflow_transaction: copy.entryable, status: "confirmed")

    stats = nil
    assert_difference -> { DebugLogEntry.where(category: "provider_sync", level: "info").count }, 1 do
      stats = @wise_item.link_jar_transfers!
    end

    assert_equal [ 1, 1 ], stats.values_at(:linked, :replaced_stale_links)
    assert_not Transfer.exists?(old_link.id)
    assert_equal eur_leg.entryable_id, Transfer.find_by!(inflow_transaction_id: jar_leg.entryable_id).outflow_transaction_id
    assert_equal %w[funds_movement funds_movement standard], leg_kinds(jar_leg, eur_leg, copy)
  end

  test "keeps a link to such a copy that a person added notes to, and reports it" do
    jar_leg, eur_leg = book(jar_deposit("5006", "100 EUR"), @jar_account, @standard_account)
    copy = book_pre_routing_copy(create_balance("GBP", "10000003"), "5006", jar_leg.date, amount: 100)
    noted = Transfer.create!(inflow_transaction: jar_leg.entryable, outflow_transaction: copy.entryable, status: "confirmed",
                             notes: "Moved to the holiday jar")

    assert_difference -> { DebugLogEntry.where(category: "provider_sync_error").count }, 1 do
      assert_equal 1, @wise_item.link_jar_transfers![:kept_link_to_copy]
    end

    assert Transfer.exists?(noted.id)
    assert_not Transfer.exists?(outflow_transaction_id: eur_leg.entryable_id)
    assert_equal [ "kept_link_to_copy" ], DebugLogEntry.order(:created_at).last.metadata["problems"].map { |problem| problem["reason"] }
  end

  # Without the move's stored row (an older payload that lost it, a source
  # balance not linked) a single leg is linked and several are left alone, and
  # a copy earlier routing booked in the move's currency on a balance in
  # another currency never counts.
  test "without a stored row links the one leg that is not a copy and leaves two alone" do
    gbp = create_balance("GBP", "10000003")
    jar_leg = leg(@jar_account, "6006_inflow", -50)
    eur_leg = leg(@standard_account, "6006_outflow", 50)
    book_pre_routing_copy(gbp, "6006", jar_leg.date, amount: 50)

    @wise_item.link_jar_transfers!

    assert_equal eur_leg.entryable_id, Transfer.find_by(inflow_transaction_id: jar_leg.entryable_id)&.outflow_transaction_id

    two_legs = leg(@jar_account, "6007_inflow", -70)
    leg(@standard_account, "6007_outflow", 70)
    leg(create_balance("EUR", "10000005", type: "SAVINGS"), "6007_outflow", 70)
    lone_inflow = leg(@jar_account, "6008_inflow", -30)
    book_pre_routing_copy(gbp, "6008", lone_inflow.date, amount: 30)

    assert_difference -> { DebugLogEntry.where(category: "provider_sync_error").count }, 1 do
      @wise_item.link_jar_transfers!
    end

    assert_not Transfer.exists?(inflow_transaction_id: two_legs.entryable_id)
    assert_not Transfer.exists?(inflow_transaction_id: lone_inflow.entryable_id)
    assert_equal [ 2, 1 ], DebugLogEntry.order(:created_at).last.metadata["problems"].map { |problem| problem["candidate_count"] }
  end

  test "leaves a conversion unlinked when two legs sit on balances in its source currency" do
    gbp_jar = create_balance("GBP", "10000005", type: "SAVINGS")
    inflow, = book(gbp_to_eur("9000000106"), @standard_account, create_balance("GBP", "10000003"))
    gbp_jar.current_account.entries.create!(external_id: "wise_interbalance_9000000106_outflow", source: "wise", amount: 1150,
                                            currency: "GBP", date: inflow.date, name: "Transfer to EUR", entryable: Transaction.new)

    assert_difference "DebugLogEntry.count", 1 do
      @wise_item.link_jar_transfers!
    end

    assert_not Transfer.exists?(inflow_transaction_id: inflow.entryable_id)
  end

  # Auto-matching no longer pairs two balances of one item, so a suggestion it
  # made before (a top-up "matching" a payout) would otherwise stay forever.
  test "discards pending suggestions between two balances of the connection" do
    usd = create_balance("USD", "10000004")
    top_up = @standard_sure_account.entries.create!(external_id: "wise_transfer_9000000104", source: "wise", amount: -2465,
                                                    currency: "EUR", date: Date.current, name: "Top-up", entryable: Transaction.new)
    payout = usd.current_account.entries.create!(external_id: "wise_transfer_9000000105", source: "wise", amount: 1618.42,
                                                 currency: "USD", date: Date.current, name: "Payout", entryable: Transaction.new)
    within_item = Transfer.create!(inflow_transaction: top_up.entryable, outflow_transaction: payout.entryable, status: "pending")
    other_payout = usd.current_account.entries.create!(external_id: "wise_transfer_9000000103", source: "wise", amount: 5482.37,
                                                       currency: "USD", date: Date.current, name: "Payout", entryable: Transaction.new)
    bank_credit = bank_entry(amount: -5482.37, date: Date.current, currency: "USD")
    with_bank = Transfer.create!(inflow_transaction: bank_credit.entryable, outflow_transaction: other_payout.entryable, status: "pending")

    @wise_item.link_jar_transfers!

    assert_not Transfer.exists?(within_item.id)
    assert Transfer.exists?(with_bank.id)
  end

  private

    def stub_sca_encryption_available
      WiseItem.stubs(:encryption_ready?).returns(true)
      WiseItem.stubs(:encrypted_attributes).returns([ "sca_private_key" ])
    end

    def create_balance(currency, balance_id, type: "STANDARD")
      wise_account = WiseAccount.create!(wise_item: @wise_item, balance_id: balance_id, name: "Wise #{currency}",
                                         currency: currency, raw_payload: { "type" => type })
      AccountProvider.create!(
        account: Account.create!(family: @family, name: "Wise #{currency}", accountable: Depository.new(subtype: "checking"),
                                 balance: 0, currency: currency),
        provider: wise_account
      )
      wise_account
    end

    # Stores the activity on each balance and books it there, as a sync does.
    def book(activity, *wise_accounts)
      wise_accounts.map do |wise_account|
        wise_account.update!(raw_transactions_payload: Array(wise_account.raw_transactions_payload) + [ activity ])
        WiseActivity::Processor.new(activity, wise_account: wise_account).process
      end
    end

    # The +primaryAmount _outflow leg the routing before currency-aware
    # conversions booked on every STANDARD balance.
    def book_pre_routing_copy(wise_account, resource_id, date, amount: 1234.56)
      wise_account.current_account.entries.create!(external_id: "wise_interbalance_#{resource_id}_outflow", source: "wise",
                                                   amount: amount, currency: "EUR", date: date, name: "Transfer to EUR",
                                                   entryable: Transaction.new)
    end

    # A leg booked before the payload kept the move's row (side: e.g.
    # "6006_inflow"), in its balance's currency.
    def leg(wise_account, side, amount)
      wise_account.current_account.entries.create!(external_id: "wise_interbalance_#{side}", source: "wise", amount: amount,
                                                   currency: wise_account.currency, date: Date.current, name: "Jar move",
                                                   entryable: Transaction.new)
    end

    def interbalance(resource_id, title:, primary:, secondary: nil)
      {
        "id" => "interbalance_activity_#{resource_id}",
        "type" => "INTERBALANCE",
        "resource" => { "type" => "BALANCE_TRANSACTION", "id" => resource_id },
        "title" => title,
        "primaryAmount" => primary,
        "secondaryAmount" => secondary,
        "status" => "COMPLETED",
        "createdOn" => "2026-03-18T09:41:27.109Z"
      }.compact
    end

    def jar_deposit(resource_id, amount)
      interbalance(resource_id, title: "To <strong>Jar</strong>", primary: amount)
    end

    def gbp_to_eur(resource_id)
      interbalance(resource_id, title: "To <strong>EUR</strong>", primary: "1,234.56 EUR", secondary: "1,000 GBP")
    end

    # A transaction on a bank account outside the Wise connection.
    def bank_entry(amount:, date:, currency: "EUR")
      bank = Account.create!(family: @family, name: "Bank #{currency}", accountable: Depository.new(subtype: "checking"),
                             balance: 0, currency: currency)
      bank.entries.create!(amount: amount, currency: currency, date: date, name: "Bank transfer", entryable: Transaction.new)
    end

    def statement_entry(wise_account, external_id, amount)
      wise_account.current_account.entries.create!(external_id: external_id, source: "wise", amount: amount, currency: wise_account.currency,
                                                   date: Date.current, name: "Wise statement", entryable: Transaction.new)
    end

    def leg_kinds(*entries)
      entries.map { |entry| entry.entryable.reload.kind }
    end
end
