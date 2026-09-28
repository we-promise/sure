# frozen_string_literal: true

require "test_helper"

class FamilyMerchantTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "preserves user-selected color on creation" do
    merchant = FamilyMerchant.create!(
      family: @family,
      name: "Custom Color Merchant",
      color: "#123456"
    )

    assert_equal "#123456", merchant.color
  end

  test "sets random default color when color is blank" do
    merchant = FamilyMerchant.create!(
      family: @family,
      name: "Default Color Merchant"
    )

    assert_includes FamilyMerchant::COLORS, merchant.color
  end

  test "preserves existing color on update" do
    merchant = FamilyMerchant.create!(
      family: @family,
      name: "Original Merchant",
      color: "#123456"
    )

    merchant.update!(name: "Renamed Merchant")
    assert_equal "#123456", merchant.reload.color
  end

  test "replaces invalid hex color with default sample" do
    merchant = FamilyMerchant.create!(
      family: @family,
      name: "Invalid Color Merchant",
      color: "invalid-color"
    )

    assert_includes FamilyMerchant::COLORS, merchant.color
  end

  test "find_or_create_with_name reuses an existing merchant instead of raising" do
    existing = FamilyMerchant.create!(family: @family, name: "Existing Merchant")

    merchant, created = FamilyMerchant.find_or_create_with_name(@family, "Existing Merchant", website_url: "https://ignored.example")

    assert_equal existing, merchant
    assert_not created
    assert_nil merchant.website_url
  end

  test "find_or_create_with_name creates a new merchant when none exists" do
    merchant, created = FamilyMerchant.find_or_create_with_name(@family, "Brand New Merchant", website_url: "https://new.example")

    assert created
    assert_equal "Brand New Merchant", merchant.name
    assert_equal "https://new.example", merchant.website_url
  end

  test "find_or_create_with_name recovers from a RecordInvalid uniqueness conflict" do
    existing = FamilyMerchant.create!(family: @family, name: "Race Merchant")
    relation = @family.merchants

    relation.stub :find_by, nil do
      merchant, created = FamilyMerchant.find_or_create_with_name(@family, "Race Merchant")

      assert_equal existing, merchant
      assert_not created
    end
  end
end

# A duplicate name reaching the database's unique index (rather than being
# caught by the model's own uniqueness validation first) needs a genuine
# second, concurrently-committing connection to reproduce: Postgres only
# raises RecordNotUnique, instead of the app-level RecordInvalid, when the
# conflicting row wasn't yet visible to this session's own validation query.
# Runs without transactional fixtures so the writer thread's commit is
# visible to the reader's separate connection.
class FamilyMerchantConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(
      name: "Race Family", currency: "USD", locale: "en", country: "US",
      date_format: "%m/%d/%Y", timezone: "UTC"
    )
  end

  teardown do
    @family.destroy
  end

  test "find_or_create_with_name survives a real unique-constraint violation without aborting the caller's transaction" do
    name = "Race Merchant"
    writer_inserted = Queue.new
    release_writer = Queue.new
    reader_pid = Queue.new
    writer = nil
    reader = nil

    begin
      writer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            FamilyMerchant.create!(family: @family, name: name)
            writer_inserted << true
            release_writer.pop
          end
        end
      end

      reader = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          reader_pid << connection.select_value("SELECT pg_backend_pid()")

          ActiveRecord::Base.transaction do
            merchant, created = FamilyMerchant.find_or_create_with_name(@family, name)
            # Proves the rescued RecordNotUnique didn't poison this transaction.
            count_inside_tx = @family.merchants.where(name: name).count
            { merchant: merchant, created: created, count_inside_tx: count_inside_tx }
          end
        end
      end

      writer_inserted.pop
      pid = reader_pid.pop.to_i

      # Wait until Postgres itself reports the reader blocked on a lock, proving
      # it reached the INSERT (not the early find_by return) and is genuinely
      # waiting on the writer's uncommitted row -- only then is releasing the
      # writer guaranteed to exercise the RecordNotUnique/savepoint path rather
      # than a RecordInvalid from a stale read, or no conflict at all.
      deadline = Time.current + 5.seconds
      wait_event_type = nil
      loop do
        wait_event_type = ActiveRecord::Base.connection.select_value(
          "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{pid}"
        )
        break if wait_event_type == "Lock" || Time.current > deadline
        sleep 0.01
      end
      assert_equal "Lock", wait_event_type, "reader never blocked on the unique index; the race wasn't reproduced"

      release_writer << true
      # .value joins the thread and re-raises any exception it raised, instead
      # of leaving the test hanging on a queue that a dead reader never pushed to.
      result = reader.value

      assert_equal name, result[:merchant].name
      assert_not result[:created]
      assert_equal 1, result[:count_inside_tx]
      assert_equal 1, @family.merchants.where(name: name).count
    ensure
      # Unblocks the writer even if an assertion above failed, so its thread
      # (and checked-out connection) don't leak past this test.
      release_writer << true
      writer&.join(2)
      reader&.join(2)
    end
  end
end
