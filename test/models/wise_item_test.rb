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

  test "links matching interbalance inflow and outflow entries as a Transfer" do
    inflow_entry  = create_interbalance_entry(@jar_sure_account, "5001", side: :inflow, amount: -1000.0)
    outflow_entry = create_interbalance_entry(@standard_sure_account, "5001", side: :outflow, amount: 1000.0)

    assert_difference "Transfer.count", 1 do
      @wise_item.link_jar_transfers!
    end

    transfer = Transfer.find_by(inflow_transaction_id: inflow_entry.entryable_id)
    assert_not_nil transfer
    assert_equal outflow_entry.entryable_id, transfer.outflow_transaction_id
    assert_equal "confirmed", transfer.status
  end

  test "does not create duplicate Transfer for already-linked pair" do
    inflow_entry  = create_interbalance_entry(@jar_sure_account, "5002", side: :inflow, amount: -2000.0)
    outflow_entry = create_interbalance_entry(@standard_sure_account, "5002", side: :outflow, amount: 2000.0)

    @wise_item.link_jar_transfers!

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end
  end

  test "skips unmatched inflow entries with no corresponding outflow" do
    create_interbalance_entry(@jar_sure_account, "5003", side: :inflow, amount: -500.0)

    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end
  end

  test "links multiple interbalance pairs in one call" do
    create_interbalance_entry(@jar_sure_account, "6001", side: :inflow, amount: -1000.0)
    create_interbalance_entry(@standard_sure_account, "6001", side: :outflow, amount: 1000.0)
    create_interbalance_entry(@jar_sure_account, "6002", side: :inflow, amount: -3000.0)
    create_interbalance_entry(@standard_sure_account, "6002", side: :outflow, amount: 3000.0)

    assert_difference "Transfer.count", 2 do
      @wise_item.link_jar_transfers!
    end
  end

  test "does nothing when no interbalance entries exist" do
    assert_no_difference "Transfer.count" do
      @wise_item.link_jar_transfers!
    end
  end

  private

    def stub_sca_encryption_available
      WiseItem.stubs(:encryption_ready?).returns(true)
      WiseItem.stubs(:encrypted_attributes).returns([ "sca_private_key" ])
    end

    def create_interbalance_entry(account, resource_id, side:, amount:)
      external_id = "wise_interbalance_#{resource_id}_#{side}"
      transaction = Transaction.create!(kind: "funds_movement")
      entry = account.entries.create!(
        external_id: external_id,
        source: "wise",
        amount: amount,
        currency: "EUR",
        date: Date.today,
        name: "Transfer to Jar",
        entryable: transaction
      )
      entry
    end
end
