require "test_helper"

class MigrationNoticeTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    # Snapshot the existing registry so we can isolate per-test fixtures
    # without losing the production-registered notices when the suite ends.
    @registry_snapshot = MigrationNotice.all
    MigrationNotice.reset!
  end

  teardown do
    MigrationNotice.reset!
    @registry_snapshot.each do |n|
      MigrationNotice.register(
        key: n.key, scope: n.scope,
        condition: n.condition, copyable_value: n.copyable_value
      )
    end
  end

  test "active_for returns notices whose condition matches and which aren't dismissed" do
    MigrationNotice.register(
      key: :always_on, scope: :test,
      condition: ->(_family) { true }
    )

    notices = MigrationNotice.active_for(family: @family, view: nil)

    assert_equal 1, notices.size
    assert_equal "always_on", notices.first[:key]
  end

  test "active_for filters by scope when given" do
    MigrationNotice.register(
      key: :provider_one, scope: :providers, condition: ->(_) { true }
    )
    MigrationNotice.register(
      key: :billing_one, scope: :billing, condition: ->(_) { true }
    )

    keys = MigrationNotice.active_for(family: @family, view: nil, scope: :providers).map { |n| n[:key] }
    assert_equal [ "provider_one" ], keys
  end

  test "active_for skips notices the family has dismissed" do
    MigrationNotice.register(
      key: :acked, scope: :test, condition: ->(_) { true }
    )
    @family.dismiss_migration_notice!(:acked)

    assert_empty MigrationNotice.active_for(family: @family, view: nil)
  end

  test "active_for skips notices whose condition returns false" do
    MigrationNotice.register(
      key: :inactive, scope: :test, condition: ->(_) { false }
    )

    assert_empty MigrationNotice.active_for(family: @family, view: nil)
  end

  test "active_for resolves copyable_value via the supplied view context" do
    view_double = Object.new
    def view_double.example_url(host:) "https://#{host}/x" end

    MigrationNotice.register(
      key: :with_uri, scope: :test, condition: ->(_) { true },
      copyable_value: ->(view) { view.example_url(host: "test.local") }
    )

    notice = MigrationNotice.active_for(family: @family, view: view_double).first
    assert_equal "https://test.local/x", notice[:copyable_value]
  end

  test "register replaces a previously-registered notice with the same key" do
    MigrationNotice.register(key: :replaceable, scope: :test, condition: ->(_) { true })
    MigrationNotice.register(key: :replaceable, scope: :test, condition: ->(_) { false })

    assert_empty MigrationNotice.active_for(family: @family, view: nil)
    assert_equal 1, MigrationNotice.all.size
  end
end
