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
    WiseItem.stubs(:encryption_ready?).returns(true)
    public_pem = @wise_item.generate_sca_keypair!

    assert @wise_item.sca_configured?
    assert_includes public_pem, "PUBLIC KEY"
    assert_equal public_pem, @wise_item.sca_public_key

    private_key = OpenSSL::PKey::RSA.new(@wise_item.sca_private_key)
    assert_equal private_key.public_key.to_pem, public_pem
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
    WiseItem.stubs(:encryption_ready?).returns(true)
    first_public_key = @wise_item.generate_sca_keypair!
    second_public_key = @wise_item.generate_sca_keypair!

    assert_not_equal first_public_key, second_public_key
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
