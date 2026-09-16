require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class Family::LegacyDestructionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    @families = []
    DebugLogEntry.stubs(:capture)
  end

  teardown do
    @families.reverse_each { |family| cleanup_family(family) }
  end

  test "the complete manifest inventory includes all 23 item types regardless of status or deletion flags" do
    family = new_family
    manifests = Provider::AccountData::MigrationManifest.all
    assert_equal 23, manifests.size
    items = manifests.map { |manifest| inventory_item(manifest, family) }
    before = items.map { |item| [ item.class.name, item.id, item.family_id ] }.sort

    result = Family::LegacyDestruction.new(family).with_admission do
      # These nested calls cannot acquire a missing item permit inside the
      # transaction, so every class must already be in the admitted set.
      items.each do |item|
        Fence.with_item(item, operation: :lifecycle) do |current|
          assert_equal item.id, current.id
          assert_equal family.id, current.family_id
          assert current.scheduled_for_deletion? if current.respond_to?(:scheduled_for_deletion?)
        end
      end
      :reviewed
    end

    assert_equal :reviewed, result
    assert_equal before, items.map { |item| [ item.class.name, item.reload.id, item.family_id ] }.sort
  end

  test "all item permits precede Stripe and Plaid callbacks and remain held through dependent Up destruction" do
    family = new_family
    first, second = 2.times.map { up_item(family) }
    plaid = PlaidItem.create!(family: family, name: "Deletion Plaid", plaid_id: SecureRandom.uuid, access_token: "private-token")
    family.create_subscription!(status: "active", stripe_id: "sub_deletion")
    stripe = mock("Stripe cancellation")
    plaid_client = mock("Plaid removal")
    Provider::Registry.stubs(:get_provider).with(:stripe).returns(stripe)
    PlaidItem.any_instance.stubs(:plaid_provider).returns(plaid_client)
    stripe.expects(:cancel_subscription).once.with do |id|
      assert_equal "sub_deletion", id
      assert_all_drains_busy([ first, second, plaid ])
      true
    end
    plaid_client.expects(:remove_item).once.with do |token|
      assert_equal "private-token", token
      assert_all_drains_busy([ first, second, plaid ])
      true
    end

    assert_same family, family.destroy
    assert family.destroyed?
    assert_not Family.exists?(family.id)
    assert_not UpItem.exists?(first.id)
    assert_not UpItem.exists?(second.id)
    assert_not PlaidItem.exists?(plaid.id)
  end

  test "one quiescing item prevents every callback and mutation including an earlier Plaid item" do
    family = new_family
    plaid = PlaidItem.create!(family: family, name: "Deletion Plaid", plaid_id: SecureRandom.uuid, access_token: "private-token")
    blocked = up_item(family)
    family.create_subscription!(status: "active", stripe_id: "sub_untouched")
    control = ProviderMigrationControl.create!(family: family, provider_key: "up", legacy_type: "UpItem", legacy_id: blocked.id, state: "quiescing")
    PlaidItem.any_instance.expects(:plaid_provider).never
    Provider::Registry.expects(:get_provider).with(:stripe).never
    before = [ family.reload.attributes, blocked.reload.attributes, plaid.reload.attributes, control.attributes ]

    queries = capture_sql_queries { assert_raises(Fence::OwnershipChanged) { family.destroy } }

    assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
    assert_equal before, [ family.reload.attributes, blocked.reload.attributes, plaid.reload.attributes, control.reload.attributes ]
  end

  test "a drain in another session refuses family destruction and releases any acquired prefix" do
    family = new_family
    first, second = 2.times.map { up_item(family) }.sort_by(&:id)
    Fence.with_exclusive(second) do
      assert_equal :busy, in_another_session do
        Family.find(family.id).destroy
        :unexpected
      rescue Fence::Busy
        :busy
      end
      assert_equal :drained, in_another_session { Fence.with_exclusive(first) { :drained } }
    end
    assert Family.exists?(family.id)
    assert_equal 2, UpItem.where(family_id: family.id).count
  end

  test "shared connections reject destruction with ordinary model errors before remote side effects" do
    with_provider_encryption do
      family = new_family
      family.provider_connections.load
      up_item(family)
      family.create_subscription!(status: "active", stripe_id: "sub_untouched")
      connection = create_provider_connection(family: family)
      Provider::Registry.expects(:get_provider).with(:stripe).never

      queries = capture_sql_queries { assert_equal false, family.destroy }

      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert family.errors.of_kind?(:base, :"restrict_dependent_destroy.has_many")
      assert_includes family.errors.full_messages.join(" "), "provider connections"
      assert Family.exists?(family.id)
      assert ProviderConnection.exists?(connection.id)
      assert_equal 1, UpItem.where(family_id: family.id).count
      assert_raises(ActiveRecord::RecordNotDestroyed) { family.destroy! }
    end
  end

  test "retained migration controls without a shared connection reject before irreversible callbacks" do
    family = new_family
    item = up_item(family)
    family.create_subscription!(status: "active", stripe_id: "sub_untouched")
    ProviderMigrationControl.create!(family: family, provider_key: "up", legacy_type: "UpItem", legacy_id: item.id, state: "legacy")
    Provider::Registry.expects(:get_provider).with(:stripe).never

    assert_equal false, family.destroy
    assert_includes family.errors.full_messages.join(" "), "provider migration controls"
    assert Family.exists?(family.id)
    assert UpItem.exists?(item.id)
  end

  test "a retained file batch without a shared connection rejects before irreversible callbacks" do
    with_provider_encryption do
      family = new_family
      item = PlaidItem.create!(family: family, name: "Deletion Plaid", plaid_id: SecureRandom.uuid, access_token: "private-token")
      family.create_subscription!(status: "active", stripe_id: "sub_untouched")
      import = PdfImport.create!(family: family)
      batch = IngestionBatch.create!(family: family, import: import, origin_kind: "file", stream: "transactions",
        scope_key: "import:#{import.id}", idempotency_key: SecureRandom.uuid, status: "review_required", payload: { "rows" => [] })
      assert_not ProviderConnection.where(family_id: family.id).exists?
      assert_not ProviderMigrationControl.where(family_id: family.id).exists?
      Provider::Registry.expects(:get_provider).with(:stripe).never
      PlaidItem.any_instance.expects(:plaid_provider).never

      queries = capture_sql_queries { assert_equal false, family.destroy }

      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert family.errors.of_kind?(:base, :"restrict_dependent_destroy.has_many")
      assert_includes family.errors.full_messages.join(" "), "ingestion batches"
      assert Family.exists?(family.id)
      assert PlaidItem.exists?(item.id)
      assert Import.exists?(import.id)
      assert IngestionBatch.exists?(batch.id)
    end
  end

  test "an item added after admission is detected before any dependent callback" do
    family = new_family
    original = up_item(family)
    family.create_subscription!(status: "active", stripe_id: "sub_untouched")
    Provider::Registry.expects(:get_provider).with(:stripe).never
    inserted = nil
    caller_thread = Thread.current
    observer = lambda do |_name, _started, _finished, _unique_id, payload|
      next unless Thread.current == caller_thread && inserted.nil? && payload[:sql].match?(/\ABEGIN\b/i)
      inserted = in_another_session { up_item(Family.find(family.id)).id }
    end

    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      assert_raises(Fence::OwnershipChanged) { family.destroy }
    end

    assert inserted
    assert Family.exists?(family.id)
    assert UpItem.exists?(original.id)
    assert UpItem.exists?(inserted)
  end

  test "the family row lock prevents a new item from joining after inventory revalidation" do
    family = new_family
    up_item(family)
    result = Family::LegacyDestruction.new(family).with_admission do
      in_another_session do
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '100ms'")
          up_item(Family.find(family.id))
        end
        :unexpected
      rescue ActiveRecord::LockWaitTimeout
        :blocked
      end
    end
    assert_equal :blocked, result
    assert_equal 1, UpItem.where(family_id: family.id).count
  end

  test "admitted item row locks prevent reparenting after the final inventory check" do
    family = new_family
    other = new_family
    item = up_item(family)
    result = Family::LegacyDestruction.new(family).with_admission do
      in_another_session do
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '100ms'")
          UpItem.where(id: item.id).update_all(family_id: other.id)
        end
        :unexpected
      rescue ActiveRecord::LockWaitTimeout
        :blocked
      end
    end
    assert_equal :blocked, result
    assert_equal family.id, item.reload.family_id
  end

  test "an existing provider row edit returns Busy instead of waiting after the family lock" do
    skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
    family = new_family
    item = up_item(family)
    entered, release = Queue.new, Queue.new
    worker = Thread.new do
      ApplicationRecord.connection_pool.with_connection do
        UpItem.find(item.id).with_lock do
          entered << true
          release.pop
        end
      end
    end
    Timeout.timeout(5) { entered.pop }

    queries = capture_sql_queries { assert_raises(Fence::Busy) { family.destroy } }

    assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
    assert Family.exists?(family.id)
  ensure
    release << true if release
    worker&.join(5)
    worker&.kill if worker&.alive?
    worker&.join
  end

  test "ordinary callback errors keep their exception instead of becoming ownership failures" do
    family = new_family
    up_item(family)
    failure = ActiveRecord::RecordNotFound.new("Ordinary callback lookup failed")
    assert_same failure, assert_raises(ActiveRecord::RecordNotFound) {
      Family::LegacyDestruction.new(family).with_admission { raise failure }
    }
    assert Family.exists?(family.id)
  end

  test "a user row held by a transfer refuses destruction before Stripe or Plaid callbacks" do
    family = new_family
    user = User.create!(family: family, email: "family-deletion-#{SecureRandom.uuid}@example.com", password: "password123", role: "admin")
    account = Account.create!(family: family, owner: user, name: "Transfer account", balance: 100, currency: "USD", accountable: Depository.new)
    item = PlaidItem.create!(family: family, name: "Deletion Plaid", plaid_id: SecureRandom.uuid, access_token: "private-token")
    family.create_subscription!(status: "active", stripe_id: "sub_untouched")
    Provider::Registry.expects(:get_provider).with(:stripe).never
    PlaidItem.any_instance.expects(:plaid_provider).never
    before = [ family.reload.attributes, user.reload.attributes, account.reload.attributes, item.reload.attributes ]

    with_row_lock_in_another_session(User, user.id, "FOR UPDATE") do
      queries = capture_sql_queries { assert_raises(Fence::Busy) { family.destroy } }
      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert_equal before, [ family.reload.attributes, user.reload.attributes, account.reload.attributes, item.reload.attributes ]
    end
  end

  test "an Account FK key share lock refuses destruction before Stripe or Plaid callbacks" do
    family = new_family
    user = User.create!(family: family, email: "family-deletion-#{SecureRandom.uuid}@example.com", password: "password123", role: "admin")
    account = Account.create!(family: family, owner: user, name: "Materializing account", balance: 100, currency: "USD", accountable: Depository.new)
    item = PlaidItem.create!(family: family, name: "Deletion Plaid", plaid_id: SecureRandom.uuid, access_token: "private-token")
    family.create_subscription!(status: "active", stripe_id: "sub_untouched")
    Provider::Registry.expects(:get_provider).with(:stripe).never
    PlaidItem.any_instance.expects(:plaid_provider).never
    before = [ family.reload.attributes, user.reload.attributes, account.reload.attributes, item.reload.attributes ]

    # Balance insertion takes this FK lock before Account validation takes User.
    # FOR NO KEY UPDATE on the deletion path would incorrectly admit this case.
    with_row_lock_in_another_session(Account, account.id, "FOR KEY SHARE") do
      queries = capture_sql_queries { assert_raises(Fence::Busy) { family.destroy } }
      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert_equal before, [ family.reload.attributes, user.reload.attributes, account.reload.attributes, item.reload.attributes ]
    end
  end

  test "a false destroy rolls back earlier dependent deletion inside an already admitted caller transaction" do
    family = new_family
    item = up_item(family)
    callback = -> { throw(:abort) if id == family.id }
    Family.set_callback(:destroy, :before, callback)

    Fence.with_items([ item ], operation: :lifecycle) do
      Family.transaction do
        assert_equal false, family.destroy
        Family.where(id: family.id).update_all(name: "Caller continues")
      end
    end

    assert UpItem.exists?(item.id), "dependent deletion escaped a failed destroy"
    assert_equal "Caller continues", family.reload.name
  ensure
    Family.skip_callback(:destroy, :before, callback) if callback
  end

  test "unadmitted caller transactions cannot acquire a nonempty family permit" do
    family = new_family
    item = up_item(family)
    assert_raises(ArgumentError) do
      Family.transaction { family.destroy }
    end
    assert Family.exists?(family.id)
    assert UpItem.exists?(item.id)
  end

  test "an oversized family inventory fails before callbacks or partial admission" do
    family = new_family
    2.times { up_item(family) }
    original = Family::LegacyDestruction::MAX_ITEMS
    Family::LegacyDestruction.send(:remove_const, :MAX_ITEMS)
    Family::LegacyDestruction.const_set(:MAX_ITEMS, 1)

    assert_raises(Fence::InvalidSource) { family.destroy }
    assert Family.exists?(family.id)
    assert_equal 2, UpItem.where(family_id: family.id).count
  ensure
    Family::LegacyDestruction.send(:remove_const, :MAX_ITEMS) if original
    Family::LegacyDestruction.const_set(:MAX_ITEMS, original) if original
  end

  test "an empty family remains destructible inside an ordinary caller transaction" do
    family = new_family
    Family.transaction { assert_same family, family.destroy }
    assert family.destroyed?
    assert_not Family.exists?(family.id)
  end

  test "stale family association caches cannot hide a newly linked legacy item or a foreign family owner" do
    family = new_family
    other = new_family
    family.up_items.load
    item = up_item(family)
    unrelated = up_item(other)
    ProviderMigrationControl.create!(family: other, provider_key: "up", legacy_type: "UpItem", legacy_id: unrelated.id, state: "quiescing")

    assert_same family, family.destroy
    assert_not UpItem.exists?(item.id)
    assert UpItem.exists?(unrelated.id)
    assert Family.exists?(other.id)
  end

  private
    def new_family
      Family.create!(name: "Family deletion test").tap { |family| @families << family }
    end

    def up_item(family)
      UpItem.create!(family: family, name: "Deletion Up", access_token: "private-up-token")
    end

    def inventory_item(manifest, family)
      # Some integrations have no YAML fixture. Credential-incomplete rows are
      # intentional: destruction must admit even failed or unconfigured items.
      required = {
        "BrexItem" => { token: "private-token" },
        "CoinstatsItem" => { api_key: "private-api-key" },
        "PlaidItem" => { plaid_id: SecureRandom.uuid },
        "RedbarkItem" => { api_key: "private-api-key" },
        "SophtronItem" => { user_id: SecureRandom.uuid, access_key: "private-access-key" },
        "WiseItem" => { token: "private-token", profile_id: SecureRandom.uuid, profile_type: "personal" }
      }
      item = manifest.item_type.constantize.new({ family: family, name: "Deletion inventory", status: "requires_update" }.merge(required.fetch(manifest.item_type, {})))
      item.scheduled_for_deletion = true if item.has_attribute?(:scheduled_for_deletion)
      item.save!(validate: false)
      item
    end

    def assert_all_drains_busy(items)
      items.each do |item|
        assert_equal :busy, in_another_session do
          Fence.with_exclusive(item) { :unexpected }
        rescue Fence::Busy
          :busy
        end
      end
    end

    def in_another_session(&block)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new { ApplicationRecord.connection_pool.with_connection(&block) }
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end

    def with_row_lock_in_another_session(model, id, lock)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          model.transaction do
            model.where(id: id).lock(lock).first!
            entered << true
            release.pop
          end
        end
      end
      Timeout.timeout(5) { entered.pop }
      yield
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end

    def cleanup_family(family)
      IngestionBatch.where(family_id: family.id).delete_all
      ProviderMigrationMapping.where(family_id: family.id).delete_all
      ProviderMigrationControl.where(family_id: family.id).delete_all
      ProviderConnection.where(family_id: family.id).delete_all
      Provider::AccountData::MigrationManifest.all.each do |manifest|
        manifest.item_type.constantize.where(family_id: family.id).delete_all
      end
      Subscription.where(family_id: family.id).delete_all
      accountables = Account.where(family_id: family.id).pluck(:accountable_type, :accountable_id)
      Account.where(family_id: family.id).delete_all
      accountables.each { |type, id| type.constantize.where(id: id).delete_all }
      User.where(family_id: family.id).delete_all
      Import.where(family_id: family.id).delete_all
      Family.where(id: family.id).delete_all
    end
end
