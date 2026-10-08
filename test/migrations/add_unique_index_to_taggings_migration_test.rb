# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261007120000_add_unique_index_to_taggings")

class AddUniqueIndexToTaggingsMigrationTest < ActiveSupport::TestCase
  INDEX = "index_taggings_unique"

  # The test schema already carries the index, so each test starts from the
  # state an installation is in before the migration runs: no index, and
  # duplicates the database was free to accept. DDL is transactional in
  # Postgres, so the removal is rolled back with the rest of the test.
  setup do
    connection.remove_index :taggings, name: INDEX, if_exists: true
    @tag = tags(:one)
    @transaction = transactions(:one)
    @kept = taggings(:one)
  end

  test "removes duplicate taggings and keeps the oldest" do
    @kept.update_columns(created_at: 2.days.ago)
    # The duplicate's id sorts below the original's, so a dedupe that kept
    # the lowest id instead of the oldest row would keep the wrong one.
    insert_tagging(id: "00000000-0000-4000-8000-000000000000", created_at: 1.day.ago)
    insert_tagging(created_at: Time.current)
    assert_equal 3, Tagging.where(tag: @tag, taggable: @transaction).count

    run_migration

    assert_equal [ @kept.id ], Tagging.where(tag: @tag, taggable: @transaction).pluck(:id)
  end

  test "leaves distinct taggings alone" do
    other = transactions(:transfer_out)
    Tagging.create!(tag: @tag, taggable: other)

    assert_no_difference -> { Tagging.count } do
      run_migration
    end

    assert_equal [ tags(:one), tags(:two) ].sort_by(&:id), @transaction.tags.sort_by(&:id)
    assert_equal [ @tag ], other.tags.to_a
  end

  # The index treats a missing taggable_type as a value like any other, so
  # duplicates without one must be cleaned too or creating it fails.
  test "removes duplicates whose taggable_type is missing" do
    2.times { insert_tagging(taggable_type: nil) }

    run_migration

    assert_equal 1, Tagging.where(tag: @tag, taggable_type: nil, taggable_id: @transaction.id).count
    assert_raises(ActiveRecord::RecordNotUnique) { insert_tagging(taggable_type: nil) }
  end

  # Rows with no taggable are outside the index, so the migration has no
  # reason to touch them.
  test "leaves rows without a taggable alone" do
    2.times { insert_tagging(taggable_type: nil, taggable_id: nil) }

    run_migration

    assert_equal 2, Tagging.where(tag: @tag, taggable_id: nil).count
  end

  test "the index refuses a duplicate afterwards" do
    run_migration

    assert_raises ActiveRecord::RecordNotUnique do
      Tagging.create!(tag: @tag, taggable: @transaction)
    end
  end

  # A duplicate inserted after the dedupe but before the index exists would
  # fail the index build, and DELETE's own lock lets inserts through. So the
  # table is locked against writers before the dedupe, and held.
  test "locks out writers from before the dedupe until the index exists" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      run_migration
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    lock_at = statements.index { |sql| sql.match?(/\ALOCK TABLE taggings IN SHARE ROW EXCLUSIVE MODE\z/) }
    delete_at = statements.index { |sql| sql.include?("DELETE FROM taggings") }
    assert lock_at, "no lock was taken on taggings"
    assert_operator lock_at, :<, delete_at, "the lock was taken after the dedupe"

    held = connection.select_values(<<~SQL)
      SELECT mode FROM pg_locks
      WHERE locktype = 'relation' AND relation = 'taggings'::regclass AND pid = pg_backend_pid()
    SQL
    assert_includes held, "ShareRowExclusiveLock", "the lock was not held to the end of the transaction"
  end

  test "can be run again" do
    2.times { run_migration }

    assert connection.index_exists?(:taggings, [ :tag_id, :taggable_type, :taggable_id ], name: INDEX, unique: true)
  end

  private
    def connection = ActiveRecord::Base.connection

    def insert_tagging(id: SecureRandom.uuid, created_at: Time.current, taggable_type: "Transaction", taggable_id: @transaction.id)
      Tagging.insert_all!([ {
        id: id, tag_id: @tag.id, taggable_type: taggable_type, taggable_id: taggable_id,
        created_at: created_at, updated_at: created_at
      } ])
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        AddUniqueIndexToTaggings.new.up
      end
    end
end
