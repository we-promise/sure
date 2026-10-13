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

  test "parse_session_expiry falls back to the configured consent_days when valid_until is missing" do
    original = Rails.configuration.x.enable_banking.consent_days
    Rails.configuration.x.enable_banking.consent_days = 120

    travel_to Time.zone.parse("2026-01-01 12:00:00") do
      expiry = @item.send(:parse_session_expiry, { access: {} })

      assert_equal 120.days.from_now.to_i, expiry.to_i
    end
  ensure
    Rails.configuration.x.enable_banking.consent_days = original
  end

  test "parse_session_expiry prefers the requested consent duration over the configured ceiling when valid_until is missing" do
    original = Rails.configuration.x.enable_banking.consent_days
    Rails.configuration.x.enable_banking.consent_days = 180

    travel_to Time.zone.parse("2026-01-01 12:00:00") do
      accepted_valid_until = 60.days.from_now
      @item.requested_consent_valid_until = accepted_valid_until

      expiry = @item.send(:parse_session_expiry, { access: {} })

      assert_equal accepted_valid_until.to_i, expiry.to_i
    end
  ensure
    Rails.configuration.x.enable_banking.consent_days = original
  end

  test "with_stale_psu_ip matches items whose session has expired" do
    expired = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Expired", country_code: "DE",
      application_id: "app", client_certificate: "cert",
      last_psu_ip: "1.2.3.4", session_id: "sess", session_expires_at: 1.day.ago
    )

    assert_includes EnableBankingItem.with_stale_psu_ip, expired
  end

  test "with_stale_psu_ip excludes items with a still-valid session" do
    active = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Active", country_code: "DE",
      application_id: "app", client_certificate: "cert",
      last_psu_ip: "1.2.3.4", session_id: "sess", session_expires_at: 1.day.from_now
    )

    assert_not_includes EnableBankingItem.with_stale_psu_ip, active
  end

  test "with_stale_psu_ip matches abandoned authorizations once the configured window elapses" do
    abandoned = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Abandoned", country_code: "DE",
      application_id: "app", client_certificate: "cert", last_psu_ip: "1.2.3.4"
    )
    abandoned.update_column(:updated_at, (Rails.configuration.x.enable_banking.consent_days + 1).days.ago)

    assert_includes EnableBankingItem.with_stale_psu_ip, abandoned
  end

  test "with_stale_psu_ip matches abandoned authorizations whose accepted consent duration has passed, even before the configured window elapses" do
    abandoned = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Abandoned short consent", country_code: "DE",
      application_id: "app", client_certificate: "cert", last_psu_ip: "1.2.3.4",
      requested_consent_valid_until: 1.day.ago
    )

    assert_includes EnableBankingItem.with_stale_psu_ip, abandoned
  end

  test "with_stale_psu_ip excludes abandoned authorizations whose accepted consent duration hasn't passed yet" do
    abandoned = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Abandoned still within consent", country_code: "DE",
      application_id: "app", client_certificate: "cert", last_psu_ip: "1.2.3.4",
      requested_consent_valid_until: 1.day.from_now
    )
    abandoned.update_column(:updated_at, (Rails.configuration.x.enable_banking.consent_days + 1).days.ago)

    assert_not_includes EnableBankingItem.with_stale_psu_ip, abandoned
  end

  test "with_stale_psu_ip excludes items without a stored last_psu_ip" do
    clean = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Clean", country_code: "DE",
      application_id: "app", client_certificate: "cert",
      session_id: "sess", session_expires_at: 1.day.ago
    )

    assert_not_includes EnableBankingItem.with_stale_psu_ip, clean
  end

  test "revoke_session clears last_psu_ip along with the session" do
    item = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Revoked", country_code: "DE",
      application_id: "app", client_certificate: "cert",
      last_psu_ip: "1.2.3.4", session_id: "sess", session_expires_at: 1.day.from_now,
      authorization_id: "auth"
    )
    provider = mock("enable_banking_provider")
    provider.expects(:delete_session).with(session_id: "sess")
    item.stubs(:enable_banking_provider).returns(provider)

    item.revoke_session
    item.reload

    assert_nil item.session_id
    assert_nil item.session_expires_at
    assert_nil item.authorization_id
    assert_nil item.last_psu_ip
  end

  test "revoke_session clears last_psu_ip even when the provider raises" do
    item = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Revoked despite provider error", country_code: "DE",
      application_id: "app", client_certificate: "cert",
      last_psu_ip: "1.2.3.4", session_id: "sess", session_expires_at: 1.day.from_now,
      authorization_id: "auth"
    )
    provider = mock("enable_banking_provider")
    provider.expects(:delete_session).with(session_id: "sess")
      .raises(Provider::EnableBanking::EnableBankingError.new("boom"))
    item.stubs(:enable_banking_provider).returns(provider)

    item.revoke_session
    item.reload

    assert_nil item.session_id
    assert_nil item.session_expires_at
    assert_nil item.authorization_id
    assert_nil item.last_psu_ip
  end
end
