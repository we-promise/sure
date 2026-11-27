require "test_helper"

class FooterTest < ActionDispatch::IntegrationTest
  # The routes read LEGAL_* when they load, which is lazy outside CI. Load them
  # before any override so /privacy and /terms keep their unset-variable routes.
  setup { Rails.application.reload_routes_unless_loaded }

  test "leaves out both legal links when neither URL is configured" do
    with_env_overrides("LEGAL_PRIVACY_URL" => nil, "LEGAL_TERMS_URL" => nil) do
      get new_session_path
    end

    assert_response :ok
    assert_select "footer a", text: "Privacy Policy", count: 0
    assert_select "footer a", text: "Terms of Service", count: 0
  end

  test "treats empty legal URLs as unset" do
    with_env_overrides("LEGAL_PRIVACY_URL" => "", "LEGAL_TERMS_URL" => "") do
      get new_session_path
    end

    assert_response :ok
    assert_select "footer a", text: "Privacy Policy", count: 0
    assert_select "footer a", text: "Terms of Service", count: 0
  end

  test "links both legal pages when both URLs are configured" do
    with_env_overrides("LEGAL_PRIVACY_URL" => "https://example.com/privacy", "LEGAL_TERMS_URL" => "https://example.com/terms") do
      get new_session_path
    end

    assert_select "footer a[href='#{privacy_path}']", text: "Privacy Policy"
    assert_select "footer a[href='#{terms_path}']", text: "Terms of Service"
    assert_select "footer span", text: "•"
  end

  test "labels the legal links in the request's locale" do
    with_env_overrides("LEGAL_PRIVACY_URL" => "https://example.com/privacy", "LEGAL_TERMS_URL" => "https://example.com/terms") do
      get new_session_path(locale: "nb")
    end

    assert_select "footer a[href='#{privacy_path}']", text: I18n.t("layouts.shared.footer.privacy_policy", locale: :nb)
    assert_select "footer a[href='#{terms_path}']", text: I18n.t("layouts.shared.footer.terms_of_service", locale: :nb)
  end

  test "links only the configured privacy page, without a separator" do
    with_env_overrides("LEGAL_PRIVACY_URL" => "https://example.com/privacy", "LEGAL_TERMS_URL" => nil) do
      get new_session_path
    end

    assert_select "footer a[href='#{privacy_path}']", text: "Privacy Policy"
    assert_select "footer a", text: "Terms of Service", count: 0
    assert_select "footer span", text: "•", count: 0
  end

  test "links only the configured terms page, without a separator" do
    with_env_overrides("LEGAL_PRIVACY_URL" => nil, "LEGAL_TERMS_URL" => "https://example.com/terms") do
      get new_session_path
    end

    assert_select "footer a[href='#{terms_path}']", text: "Terms of Service"
    assert_select "footer a", text: "Privacy Policy", count: 0
    assert_select "footer span", text: "•", count: 0
  end

  test "legal pages still render their placeholder when no URL is configured" do
    with_env_overrides("LEGAL_PRIVACY_URL" => nil, "LEGAL_TERMS_URL" => nil) do
      Rails.application.reload_routes!

      get privacy_path
      assert_response :ok
      assert_includes response.body, I18n.t("pages.privacy.placeholder")

      get terms_path
      assert_response :ok
      assert_includes response.body, I18n.t("pages.terms.placeholder")
    end
  ensure
    Rails.application.reload_routes!
  end
end
