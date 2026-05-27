# frozen_string_literal: true

require "test_helper"

class EnableBankingItemTest < ActiveSupport::TestCase
  test ".preferred_auth_method picks REDIRECT over DECOUPLED regardless of order" do
    aspsp_data = {
      auth_methods: [
        { name: "decoupled-bankid", approach: "DECOUPLED" },
        { name: "redirect-bankid",  approach: "REDIRECT"  }
      ]
    }

    method = EnableBankingItem.preferred_auth_method(aspsp_data)

    assert_equal "REDIRECT", method[:approach]
    assert_equal "redirect-bankid", method[:name]
  end

  test ".preferred_auth_method picks EMBEDDED over DECOUPLED when REDIRECT absent" do
    aspsp_data = {
      auth_methods: [
        { name: "dec", approach: "DECOUPLED" },
        { name: "emb", approach: "EMBEDDED" }
      ]
    }

    assert_equal "EMBEDDED", EnableBankingItem.preferred_auth_method(aspsp_data)[:approach]
  end

  test ".preferred_auth_method returns the only method when ASPSP exposes one" do
    aspsp_data = { auth_methods: [ { name: "only", approach: "REDIRECT" } ] }

    assert_equal "only", EnableBankingItem.preferred_auth_method(aspsp_data)[:name]
  end

  test ".preferred_auth_method returns DECOUPLED when it's the only option" do
    aspsp_data = { auth_methods: [ { name: "dec-only", approach: "DECOUPLED" } ] }

    # Controller is responsible for blocking on approach=="DECOUPLED"; this helper
    # only ranks the methods. Returning the DECOUPLED method (rather than nil)
    # keeps the API honest about what's available.
    assert_equal "DECOUPLED", EnableBankingItem.preferred_auth_method(aspsp_data)[:approach]
  end

  test ".preferred_auth_method handles nil/empty input" do
    assert_nil EnableBankingItem.preferred_auth_method(nil)
    assert_nil EnableBankingItem.preferred_auth_method({})
    assert_nil EnableBankingItem.preferred_auth_method(auth_methods: [])
  end

  test ".preferred_auth_method filters by psu_type when given" do
    # ASPSP exposes REDIRECT only for business and DECOUPLED for personal.
    # A personal-PSU caller must NOT get the business-only REDIRECT method,
    # because EB binds the chosen method's psu_type and the /auth call would
    # fail or land in the wrong flow.
    aspsp_data = {
      auth_methods: [
        { name: "biz-redirect",  approach: "REDIRECT",  psu_type: "business" },
        { name: "per-decoupled", approach: "DECOUPLED", psu_type: "personal" }
      ]
    }

    personal = EnableBankingItem.preferred_auth_method(aspsp_data, psu_type: "personal")
    business = EnableBankingItem.preferred_auth_method(aspsp_data, psu_type: "business")

    assert_equal "per-decoupled", personal[:name], "personal PSU must not pick a business-only method"
    assert_equal "biz-redirect", business[:name]
  end

  test ".preferred_auth_method returns nil when all methods target a different PSU type" do
    # An ASPSP that exposes only business-typed methods being asked for a
    # personal PSU: returning the business method would make EB's /auth fail
    # or land in the wrong flow (psu_type binding mismatch). nil tells the
    # caller to drop the explicit auth_method so EB picks its own default
    # (which will likely still fail — but won't *guarantee* a wrong-PSU bind).
    aspsp_data = {
      auth_methods: [
        { name: "biz-only-1", approach: "REDIRECT",  psu_type: "business" },
        { name: "biz-only-2", approach: "DECOUPLED", psu_type: "business" }
      ]
    }

    assert_nil EnableBankingItem.preferred_auth_method(aspsp_data, psu_type: "personal")
  end

  test ".preferred_auth_method treats methods without psu_type as PSU-type-agnostic" do
    # EB's older catalog entries don't always carry psu_type on the method.
    # Treat those as applying to any PSU — otherwise we'd reject every
    # legacy single-method bank.
    aspsp_data = {
      auth_methods: [ { name: "legacy", approach: "REDIRECT" } ]
    }

    assert_equal "legacy", EnableBankingItem.preferred_auth_method(aspsp_data, psu_type: "personal")[:name]
  end

  test ".preferred_auth_method accepts string keys (raw HTTParty response)" do
    aspsp_data = {
      "auth_methods" => [
        { "name" => "dec", "approach" => "DECOUPLED" },
        { "name" => "red", "approach" => "REDIRECT" }
      ]
    }

    assert_equal "REDIRECT", EnableBankingItem.preferred_auth_method(aspsp_data)[:approach]
  end

  test "#start_authorization fallback respects psu_type when caller passed no auth_method" do
    # Regression guard: when the caller hands us aspsp_data but no explicit
    # auth_method (older callsite, or controller's filter correctly returned
    # nil), the fallback inside start_authorization must NOT recompute the
    # preferred method without psu_type — that would bypass the PSU filter
    # and could bind a business-only method to a personal /auth request.
    require "openssl"

    family = families(:dylan_family)
    item = family.enable_banking_items.create!(
      name: "Test", country_code: "SE",
      application_id: "app", client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
    )

    aspsp_data = {
      psu_types: [ "personal", "business" ],
      auth_methods: [
        { name: "biz-redirect", approach: "REDIRECT",  psu_type: "business" },
        { name: "per-decoupled", approach: "DECOUPLED", psu_type: "personal" }
      ]
    }

    Provider::EnableBanking.any_instance.expects(:start_authorization).with do |args|
      # The fallback should pick the personal method (DECOUPLED) — not the
      # business-only REDIRECT. The controller is responsible for rejecting
      # this further upstream; the model's job here is only to not lie about
      # which method it picked.
      args[:auth_method] == "per-decoupled"
    end.returns(url: "https://api.enablebanking.com/auth/x", authorization_id: "a1")

    item.start_authorization(
      aspsp_name: "MixedBank",
      redirect_url: "https://example.com/cb",
      psu_type: "personal",
      aspsp_data: aspsp_data
    )
  end
end
