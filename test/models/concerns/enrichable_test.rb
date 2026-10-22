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
end
