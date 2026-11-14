require "test_helper"

class EnrichableTest < ActiveSupport::TestCase
  setup do
    @enrichable = accounts(:depository)
  end

  test "can enrich multiple attributes" do
    assert_difference "DataEnrichment.count", 2 do
      @enrichable.enrich_attributes({ name: "Updated Checking", balance: 6_000 }, source: "plaid")
    end

    assert_equal "Updated Checking", @enrichable.name
    assert_equal 6_000, @enrichable.balance.to_d
  end

  test "can enrich a single attribute" do
    assert_difference "DataEnrichment.count", 1 do
      @enrichable.enrich_attribute(:name, "Single Update", source: "ai")
    end

    assert_equal "Single Update", @enrichable.name
  end

  test "can lock an attribute" do
    refute @enrichable.locked?(:name)

    @enrichable.lock_attr!(:name)
    assert @enrichable.locked?(:name)
  end

  test "can unlock an attribute" do
    @enrichable.lock_attr!(:name)
    assert @enrichable.locked?(:name)

    @enrichable.unlock_attr!(:name)
    refute @enrichable.locked?(:name)
  end

  test "can lock saved attributes" do
    @enrichable.name = "User Override"
    @enrichable.balance = 1_234
    @enrichable.save!

    @enrichable.lock_saved_attributes!

    assert @enrichable.locked?(:name)
    assert @enrichable.locked?(:balance)
  end

  test "does not enrich locked attributes" do
    original_name = @enrichable.name

    @enrichable.lock_attr!(:name)

    assert_no_difference "DataEnrichment.count" do
      @enrichable.enrich_attribute(:name, "Should Not Change", source: "plaid")
    end

    assert_equal original_name, @enrichable.reload.name
  end

  test "enrichable? reflects lock state" do
    assert @enrichable.enrichable?(:name)

    @enrichable.lock_attr!(:name)

    refute @enrichable.enrichable?(:name)
  end

  test "enrichable scope includes and excludes records based on lock state" do
    # Initially, the record should be enrichable for :name
    assert_includes Account.enrichable(:name), @enrichable

    @enrichable.lock_attr!(:name)

    refute_includes Account.enrichable(:name), @enrichable
  end

  # DataEnrichment rows record who set an attribute, so they are written only
  # after a save the record accepted, and only for records that already
  # existed when the call began.

  test "does not log enrichment when save is refused" do
    @enrichable.stubs(:save).returns(false)

    assert_no_difference "DataEnrichment.count" do
      @enrichable.enrich_attribute(:name, "Refused Save", source: "plaid")
    end
  end

  # No stub: the record's own validation refuses the write, so the savepoint
  # really rolls back and ActiveRecord restores the record's transaction
  # state. Callers such as RedbarkAccount::LoanDetailsProcessor#write read
  # errors afterwards, inside their own transaction, to decide whether to
  # roll back too, so the errors must survive that restore.
  test "a save refused by validation returns false and keeps its errors" do
    stored_name = @enrichable.name

    result = nil
    assert_no_difference "DataEnrichment.count" do
      Account.transaction do
        result = @enrichable.enrich_attribute(:name, "", source: "plaid")
      end
    end

    assert_equal false, result
    assert_includes @enrichable.errors.attribute_names, :name
    assert_equal stored_name, Account.find(@enrichable.id).name
  end

  test "does not log enrichment for a new record that a real save persists" do
    # The record crosses from new to persisted inside enrich_attributes, so
    # the log decision must use the state captured before the save.
    new_record = Account.new(
      family: families(:dylan_family),
      name: "Unsaved Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    assert new_record.new_record?

    assert_no_difference "DataEnrichment.count" do
      assert new_record.enrich_attribute(:name, "Named On Create", source: "plaid")
    end

    assert new_record.persisted?
    assert_equal "Named On Create", Account.find(new_record.id).name
    assert_empty DataEnrichment.where(enrichable: new_record)
  end

  test "a refused save keeps the previously accepted provenance value" do
    # log_enrichment finds or creates the row for (record, attribute, source)
    # and overwrites its value, so a refused write that still logged would
    # replace the accepted value without changing the row count.
    @enrichable.enrich_attribute(:name, "Accepted Name", source: "plaid")
    row = DataEnrichment.find_by!(enrichable: @enrichable, attribute_name: "name", source: "plaid")
    assert_equal "Accepted Name", row.value

    @enrichable.stubs(:save).returns(false)
    @enrichable.enrich_attribute(:name, "Refused Name", source: "plaid")

    assert_equal "Accepted Name", row.reload.value
    assert_equal "Accepted Name", Account.find(@enrichable.id).name
  end

  test "a refused save rolls back association writes made by a virtual setter" do
    # On a persisted record, tag_ids= inserts the join rows before save runs.
    # The call runs inside a caller-held transaction, as the provider import
    # adapter's do, so the rollback must not depend on being the outermost.
    txn = transactions(:one)
    tag = tags(:three)
    tags_before = txn.tag_ids.sort
    refute_includes tags_before, tag.id

    txn.stubs(:save).returns(false)

    result = nil
    assert_no_difference -> { DataEnrichment.where(enrichable: txn).count } do
      Transaction.transaction do
        result = txn.enrich_attribute(:tag_ids, tags_before + [ tag.id ], source: "rule")
      end
    end

    assert_equal false, result
    assert_equal tags_before, Transaction.find(txn.id).tag_ids.sort
  end

  test "a refused virtual setter write leaves the instance reading the stored tags" do
    # The rollback removes the join rows, but tag_ids= also filled the
    # in-memory association. Left alone, the same instance would report the
    # refused tags as current, and a retry would be skipped as unchanged.
    txn = transactions(:one)
    tag = tags(:three)
    tags_before = txn.tag_ids.sort
    taggings_before = txn.taggings.map(&:tag_id).sort
    wanted = tags_before + [ tag.id ]

    txn.stubs(:save).returns(false)
    assert_equal false, txn.enrich_attribute(:tag_ids, wanted, source: "rule")

    assert_equal tags_before, txn.tag_ids.sort
    assert_equal taggings_before, txn.taggings.map(&:tag_id).sort

    txn.unstub(:save)
    assert txn.enrich_attribute(:tag_ids, wanted, source: "rule")
    assert_equal wanted.sort, Transaction.find(txn.id).tag_ids.sort
  end

  test "enriches a virtual attribute (tag_ids) and logs it after save" do
    # transactions(:one) already carries tags one and two; tag three is new.
    txn = transactions(:one)
    tag = tags(:three)

    refute_includes txn.tag_ids, tag.id

    assert_difference "DataEnrichment.count", 1 do
      assert txn.enrich_attribute(:tag_ids, [ tag.id ], source: "rule")
    end

    assert_includes txn.reload.tag_ids, tag.id

    de = DataEnrichment.where(enrichable: txn).order(:created_at).last
    assert_equal "tag_ids", de.attribute_name
    assert_equal "rule", de.source
  end

  # enrich_attributes_unless_refused returns nil, or the messages of a save the
  # record refused. A refusal leaves the record as it was loaded, so a later
  # write in the same sync is judged on its own values.

  test "an accepted write through enrich_attributes_unless_refused returns nil" do
    result = nil
    assert_difference "DataEnrichment.count", 1 do
      result = @enrichable.enrich_attributes_unless_refused({ name: "Accepted" }, source: "plaid")
    end

    assert_nil result
    assert_equal "Accepted", Account.find(@enrichable.id).name
  end

  test "a refused write returns its messages and leaves the record as loaded" do
    stored_name = @enrichable.name

    result = nil
    assert_no_difference "DataEnrichment.count" do
      result = @enrichable.enrich_attributes_unless_refused({ name: "" }, source: "plaid")
    end

    assert_equal [ "Name can't be blank" ], result
    assert_equal stored_name, @enrichable.name, "the refused value is still assigned"
    assert_empty @enrichable.errors, "the refusal's errors were left behind"
    assert_equal stored_name, Account.find(@enrichable.id).name
  end

  test "a refusal inside a caller's transaction rolls back only its own writes" do
    Account.transaction do
      @enrichable.enrich_attribute(:balance, 7_000, source: "plaid")
      assert_not_nil @enrichable.enrich_attributes_unless_refused({ name: "" }, source: "plaid")
    end

    assert_equal 7_000, Account.find(@enrichable.id).balance.to_d, "the caller's earlier write was rolled back"
    assert DataEnrichment.exists?(enrichable: @enrichable, attribute_name: "balance", source: "plaid")
  end

  # enrich_attributes returns early when every attribute is locked or
  # unchanged, so errors left by a refusal would read as a second one. Locked
  # first: lock_attr! validates, which would clear the errors on its own.
  test "a locked write after a refusal returns nil" do
    @enrichable.lock_attr!(:balance)
    assert_not_nil @enrichable.enrich_attributes_unless_refused({ name: "" }, source: "plaid")

    assert_nil @enrichable.enrich_attributes_unless_refused({ balance: 7_000 }, source: "plaid")
  end

  # The steps run in order and land together. A later step may be a callable,
  # evaluated once the earlier ones have saved.
  test "a refused later step rolls back the earlier step's save, in memory too" do
    stored_balance = @enrichable.balance.to_d
    seen_balance = nil

    result = nil
    assert_no_difference "DataEnrichment.count" do
      result = @enrichable.enrich_attributes_unless_refused(
        { balance: 7_000 },
        -> { seen_balance = @enrichable.balance.to_d; { name: "" } },
        source: "plaid"
      )
    end

    assert_equal 7_000, seen_balance, "the callable ran before the earlier step saved"
    assert_equal [ "Name can't be blank" ], result
    assert_equal stored_balance, Account.find(@enrichable.id).balance.to_d, "the earlier step landed without the later one"
    assert_equal stored_balance, @enrichable.balance.to_d, "the rolled-back save's value is still in memory"
    assert_empty @enrichable.errors
  end

  test "blank steps are skipped" do
    assert_difference "DataEnrichment.count", 1 do
      assert_nil @enrichable.enrich_attributes_unless_refused({}, -> { nil }, { name: "Accepted" }, source: "plaid")
    end
  end
end
