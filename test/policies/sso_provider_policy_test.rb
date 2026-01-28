require "test_helper"

class SsoProviderPolicyTest < ActiveSupport::TestCase
  def setup
    @super_admin = users(:family_admin) # Assuming this fixture has super_admin role
    @super_admin.update!(role: :super_admin)

    @regular_user = users(:family_member)
    @regular_user.update!(role: :member)

    @provider = SsoProvider.create!(
      strategy: "openid_connect",
      name: "test_provider",
      label: "Test Provider",
      client_id: "test",
      client_secret: "secret",
      issuer: "https://test.example.com"
    )
  end

  test "super admin can view index" do
    assert SsoProviderPolicy.new(@super_admin, SsoProvider).index?
  end

  test "regular user cannot view index" do
    assert_not SsoProviderPolicy.new(@regular_user, SsoProvider).index?
  end

  test "nil user cannot view index" do
    assert_not SsoProviderPolicy.new(nil, SsoProvider).index?
  end

  test "super admin can show provider" do
    assert SsoProviderPolicy.new(@super_admin, @provider).show?
  end

  test "regular user cannot show provider" do
    assert_not SsoProviderPolicy.new(@regular_user, @provider).show?
  end

  test "super admin can create provider" do
    assert SsoProviderPolicy.new(@super_admin, SsoProvider.new).create?
  end

  test "regular user cannot create provider" do
    assert_not SsoProviderPolicy.new(@regular_user, SsoProvider.new).create?
  end

  test "super admin can access new" do
    assert SsoProviderPolicy.new(@super_admin, SsoProvider.new).new?
  end

  test "regular user cannot access new" do
    assert_not SsoProviderPolicy.new(@regular_user, SsoProvider.new).new?
  end

  test "super admin can update provider" do
    assert SsoProviderPolicy.new(@super_admin, @provider).update?
  end

  test "regular user cannot update provider" do
    assert_not SsoProviderPolicy.new(@regular_user, @provider).update?
  end

  test "super admin can access edit" do
    assert SsoProviderPolicy.new(@super_admin, @provider).edit?
  end

  test "regular user cannot access edit" do
    assert_not SsoProviderPolicy.new(@regular_user, @provider).edit?
  end

  test "super admin can destroy provider" do
    assert SsoProviderPolicy.new(@super_admin, @provider).destroy?
  end

  test "regular user cannot destroy provider" do
    assert_not SsoProviderPolicy.new(@regular_user, @provider).destroy?
  end

  test "super admin can toggle provider" do
    assert SsoProviderPolicy.new(@super_admin, @provider).toggle?
  end

  test "regular user cannot toggle provider" do
    assert_not SsoProviderPolicy.new(@regular_user, @provider).toggle?
  end

  test "super admin can test connection" do
    assert SsoProviderPolicy.new(@super_admin, @provider).test_connection?
  end

  test "regular user cannot test connection" do
    assert_not SsoProviderPolicy.new(@regular_user, @provider).test_connection?
  end

  test "scope returns all providers for super admin" do
    SsoProvider.create!(
      strategy: "google_oauth2",
      name: "google",
      label: "Google",
      client_id: "test",
      client_secret: "secret"
    )

    scope = SsoProviderPolicy::Scope.new(@super_admin, SsoProvider).resolve
    assert_equal 2, scope.count
  end

  test "scope returns no providers for regular user" do
    scope = SsoProviderPolicy::Scope.new(@regular_user, SsoProvider).resolve
    assert_equal 0, scope.count
  end

  test "scope returns no providers for nil user" do
    scope = SsoProviderPolicy::Scope.new(nil, SsoProvider).resolve
    assert_equal 0, scope.count
  end
end
