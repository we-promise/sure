require "test_helper"

class DirectaItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @admin = users(:family_admin)
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
  end

  test "Directa is tenant-wide and remains admin-only" do
    assert_equal :tenant_wide, DirectaItem.declared_credential_scope
    assert_not DirectaItem.member_connectable?
  end

  test "owner must belong to the same family" do
    item = @family.directa_items.new(owner: users(:empty))

    assert_not item.valid?
    assert_includes item.errors[:owner], "is invalid"
  end

  test "session readiness requires an active owner, explicit encryption and a connected identity" do
    item = connected_item

    assert item.ready_for_sync?
    assert item.session_configured?

    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    assert_not item.ready_for_sync?
    assert item.session_configured?

    item.status = :requires_update
    assert_not item.session_configured?
  end

  test "verified session reconstruction contains only the encrypted account session fields" do
    item = connected_item

    session = item.verified_session

    assert_instance_of Provider::Directa::VerifiedSession, session
    assert_equal item.account_identity, session.account_identity
    assert_equal item.multi_token, session.multi_token
    assert_equal item.mono_token, session.mono_token
    assert_equal item.connection_generation, session.connection_generation
    assert_equal Provider::Directa::HOST, session.host
    assert_instance_of Provider::Directa, item.provider
  end

  test "directa session fields are encrypted at rest" do
    item = connected_item
    item.save!

    stored_values = ActiveRecord::Base.connection.select_one(
      "SELECT broker_account, account_identity, multi_token, mono_token FROM directa_items WHERE id = #{ActiveRecord::Base.connection.quote(item.id)}"
    )

    {
      "broker_account" => "00123",
      "account_identity" => "verified-account-123",
      "multi_token" => "multi-token-secret",
      "mono_token" => "mono-token-secret"
    }.each do |attribute, cleartext|
      refute_equal cleartext, stored_values.fetch(attribute)
      assert_equal cleartext, item.reload.public_send(attribute)
    end
  end

  test "disconnect invalidates authentication but preserves the provider snapshot and generation boundary" do
    item = connected_item
    item.update!(portfolio_snapshot_at: 1.day.ago)
    account = DirectaAccount.create!(
      directa_item: item,
      currency: "EUR",
      current_balance: BigDecimal("120"),
      cash_balance: BigDecimal("20"),
      raw_position_metadata: []
    )
    generation = item.connection_generation

    item.disconnect!

    assert item.reload.requires_update?
    assert_not item.session_configured?
    assert_equal generation + 1, item.connection_generation
    assert_equal "00123", item.broker_account
    assert_equal "verified-account-123", item.account_identity
    assert_equal account.id, item.directa_accounts.sole.id
    assert_equal BigDecimal("120"), account.reload.current_balance
    assert_equal 1.day.ago.to_i, item.portfolio_snapshot_at.to_i
  end

  private

    def connected_item
      DirectaItem.create!(
        family: @family,
        owner: @admin,
        broker_account: "00123",
        account_identity: "verified-account-123",
        multi_token: "multi-token-secret",
        mono_token: "mono-token-secret",
        status: :connected,
        connection_generation: 3
      )
    end
end
