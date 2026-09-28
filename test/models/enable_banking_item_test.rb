require "test_helper"

class EnableBankingItemTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @item = EnableBankingItem.new(
      family: families(:dylan_family),
      name: "Test",
      country_code: "DE",
      application_id: "app",
      client_certificate: "cert", sync_start_date: 3.months.ago.to_date
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
      application_id: "app", client_certificate: "cert", sync_start_date: 3.months.ago.to_date,
      last_psu_ip: "1.2.3.4", session_id: "sess", session_expires_at: 1.day.ago
    )

    assert_includes EnableBankingItem.with_stale_psu_ip, expired
  end

  test "with_stale_psu_ip excludes items with a still-valid session" do
    active = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Active", country_code: "DE",
      application_id: "app", client_certificate: "cert", sync_start_date: 3.months.ago.to_date,
      last_psu_ip: "1.2.3.4", session_id: "sess", session_expires_at: 1.day.from_now
    )

    assert_not_includes EnableBankingItem.with_stale_psu_ip, active
  end

  test "with_stale_psu_ip matches abandoned authorizations once the configured window elapses" do
    abandoned = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Abandoned", country_code: "DE",
      application_id: "app", client_certificate: "cert", sync_start_date: 3.months.ago.to_date, last_psu_ip: "1.2.3.4"
    )
    abandoned.update_column(:updated_at, (Rails.configuration.x.enable_banking.consent_days + 1).days.ago)

    assert_includes EnableBankingItem.with_stale_psu_ip, abandoned
  end

  test "with_stale_psu_ip matches abandoned authorizations whose accepted consent duration has passed, even before the configured window elapses" do
    abandoned = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Abandoned short consent", country_code: "DE",
      application_id: "app", client_certificate: "cert", sync_start_date: 3.months.ago.to_date, last_psu_ip: "1.2.3.4",
      requested_consent_valid_until: 1.day.ago
    )

    assert_includes EnableBankingItem.with_stale_psu_ip, abandoned
  end

  test "with_stale_psu_ip excludes abandoned authorizations whose accepted consent duration hasn't passed yet" do
    abandoned = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Abandoned still within consent", country_code: "DE",
      application_id: "app", client_certificate: "cert", sync_start_date: 3.months.ago.to_date, last_psu_ip: "1.2.3.4",
      requested_consent_valid_until: 1.day.from_now
    )
    abandoned.update_column(:updated_at, (Rails.configuration.x.enable_banking.consent_days + 1).days.ago)

    assert_not_includes EnableBankingItem.with_stale_psu_ip, abandoned
  end

  test "with_stale_psu_ip excludes items without a stored last_psu_ip" do
    clean = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Clean", country_code: "DE",
      application_id: "app", client_certificate: "cert", sync_start_date: 3.months.ago.to_date,
      session_id: "sess", session_expires_at: 1.day.ago
    )

    assert_not_includes EnableBankingItem.with_stale_psu_ip, clean
  end

  test "revoke_session clears last_psu_ip along with the session" do
    item = EnableBankingItem.create!(
      family: families(:dylan_family), name: "Revoked", country_code: "DE",
      application_id: "app", client_certificate: "cert", sync_start_date: 3.months.ago.to_date,
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
      application_id: "app", client_certificate: "cert", sync_start_date: 3.months.ago.to_date,
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

  test "sync_strategy defaults to date" do
    assert @item.date?
    assert_not @item.longest?
  end

  test "is valid without sync_start_date before setup collects it" do
    # create/authorize build the connection before the setup modal asks for
    # sync_start_date, so a blank value must not block those paths.
    @item.sync_start_date = nil

    assert @item.valid?
  end

  test "is invalid when a stored sync_start_date is cleared" do
    @item.save!
    @item.sync_start_date = nil

    assert_not @item.valid?
    assert_includes @item.errors[:sync_start_date], "can't be blank"
  end

  test "is invalid when sync_start_date is a malformed value that Rails coerces to nil" do
    @item.sync_start_date = "not-a-date"

    assert_not @item.valid?
    assert_includes @item.errors[:sync_start_date], "is not a valid date"
  end

  test "is invalid when sync_strategy is date and sync_start_date is in the future" do
    @item.sync_start_date = 1.day.from_now.to_date

    assert_not @item.valid?
    assert_includes @item.errors[:sync_start_date], "must be within the last 2 years"
  end

  test "is invalid when sync_strategy is date and sync_start_date is more than 2 years ago" do
    @item.sync_start_date = 2.years.ago.to_date - 1.day

    assert_not @item.valid?
    assert_includes @item.errors[:sync_start_date], "must be within the last 2 years"
  end

  test "is valid when sync_strategy is longest even without sync_start_date" do
    @item.sync_strategy = "longest"
    @item.sync_start_date = nil

    assert @item.valid?
  end

  test "does not revalidate sync_start_date bounds on unrelated updates once it ages past 2 years" do
    @item.save!
    @item.update_column(:sync_start_date, 2.years.ago.to_date - 1.day)
    @item.reload

    assert @item.valid?
    assert @item.update(status: :requires_update)
  end

  test "is invalid when sync_start_date is edited to a date outside the bounds" do
    @item.save!
    @item.update_column(:sync_start_date, 2.years.ago.to_date - 1.day)
    @item.reload

    @item.sync_start_date = 3.years.ago.to_date

    assert_not @item.valid?
    assert_includes @item.errors[:sync_start_date], "must be within the last 2 years"
  end

  test "sync_start_date_shortfall? is false when sync_strategy is longest" do
    @item.sync_strategy = "longest"
    @item.sync_start_date = nil

    assert_not @item.sync_start_date_shortfall?
  end

  test "sync_start_date_shortfall? is false when no effective_sync_start_date has been recorded yet" do
    @item.sync_start_date = 1.year.ago.to_date
    @item.effective_sync_start_date = nil

    assert_not @item.sync_start_date_shortfall?
  end

  test "sync_start_date_shortfall? is false when the bank honored the requested date" do
    @item.sync_start_date = 90.days.ago.to_date
    @item.effective_sync_start_date = 90.days.ago.to_date

    assert_not @item.sync_start_date_shortfall?
  end

  test "sync_start_date_shortfall? is true when the bank granted a materially newer date than requested" do
    @item.sync_start_date = 1.year.ago.to_date
    @item.effective_sync_start_date = 90.days.ago.to_date

    assert @item.sync_start_date_shortfall?
  end

  test "sync_start_date_shortfall? is false when an account simply has no early transactions despite the bank honoring the date" do
    @item.sync_start_date = 1.year.ago.to_date
    @item.effective_sync_start_date = 1.year.ago.to_date
    @item.save!
    enable_banking_account = @item.enable_banking_accounts.create!(uid: "uid_1", name: "Acct", currency: "USD")
    account = Account.create!(family: @item.family, name: "Linked", balance: 0, cash_balance: 0, currency: "USD", accountable: Depository.new)
    AccountProvider.create!(account: account, provider: enable_banking_account)
    create_transaction(account: account, date: 90.days.ago.to_date)

    assert_not @item.sync_start_date_shortfall?
  end
end
