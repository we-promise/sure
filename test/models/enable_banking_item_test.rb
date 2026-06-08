require "test_helper"

class EnableBankingItemTest < ActiveSupport::TestCase
  setup do
    @item = EnableBankingItem.new(
      family: families(:dylan_family),
      name: "Test",
      country_code: "DE",
      application_id: "app",
      client_certificate: "cert"
    )
  end

  test "select_auth_method prefers REDIRECT over DECOUPLED and EMBEDDED" do
    aspsp = {
      auth_methods: [
        { name: "decoupled_app", approach: "DECOUPLED" },
        { name: "redirect_web", approach: "REDIRECT" },
        { name: "embedded_form", approach: "EMBEDDED" }
      ]
    }.with_indifferent_access

    selected = @item.send(:select_auth_method, aspsp, "personal")

    assert_equal "redirect_web", selected[:name]
    assert_equal "REDIRECT", selected[:approach]
  end

  test "select_auth_method falls back to DECOUPLED when no REDIRECT exists" do
    aspsp = {
      auth_methods: [
        { name: "embedded_form", approach: "EMBEDDED" },
        { name: "decoupled_app", approach: "DECOUPLED" }
      ]
    }.with_indifferent_access

    selected = @item.send(:select_auth_method, aspsp, "personal")

    assert_equal "decoupled_app", selected[:name]
    assert_equal "DECOUPLED", selected[:approach]
  end

  test "select_auth_method filters by psu_type when methods declare one" do
    aspsp = {
      auth_methods: [
        { name: "business_redirect", approach: "REDIRECT", psu_type: "business" },
        { name: "personal_decoupled", approach: "DECOUPLED", psu_type: "personal" }
      ]
    }.with_indifferent_access

    selected = @item.send(:select_auth_method, aspsp, "personal")

    assert_equal "personal_decoupled", selected[:name]
  end

  test "select_auth_method ignores hidden methods" do
    aspsp = {
      auth_methods: [
        { name: "hidden_redirect", approach: "REDIRECT", hidden_method: true },
        { name: "decoupled_app", approach: "DECOUPLED" }
      ]
    }.with_indifferent_access

    selected = @item.send(:select_auth_method, aspsp, "personal")

    assert_equal "decoupled_app", selected[:name]
  end

  test "select_auth_method returns nil when no auth methods present" do
    assert_nil @item.send(:select_auth_method, { auth_methods: [] }.with_indifferent_access, "personal")
  end

  test "select_auth_method returns nil when every method is hidden" do
    aspsp = {
      auth_methods: [
        { name: "hidden_a", approach: "REDIRECT", hidden_method: true },
        { name: "hidden_b", approach: "DECOUPLED", hidden_method: true }
      ]
    }.with_indifferent_access

    # All methods hidden -> fall back to the ASPSP default rather than forcing one.
    assert_nil @item.send(:select_auth_method, aspsp, "personal")
  end

  test "reconcile_session_expiry! updates session_expires_at from access.valid_until" do
    @item.session_id = "sess"
    @item.session_expires_at = 1.day.from_now
    @item.save!
    new_expiry = 60.days.from_now.change(usec: 0)

    @item.reconcile_session_expiry!({ access: { valid_until: new_expiry.iso8601 } })

    assert_equal new_expiry.to_i, @item.reload.session_expires_at.to_i
  end

  test "reconcile_session_expiry! is a no-op when valid_until is missing" do
    @item.session_id = "sess"
    original = 1.day.from_now.change(usec: 0)
    @item.session_expires_at = original
    @item.save!

    @item.reconcile_session_expiry!({ access: {} })

    assert_equal original.to_i, @item.reload.session_expires_at.to_i
  end
end
