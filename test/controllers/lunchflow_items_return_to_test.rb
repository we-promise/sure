require "test_helper"

class LunchflowItemsReturnToTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    provider = mock("lunchflow_provider")
    provider.stubs(:get_accounts).returns(accounts: [ { id: "acc_1", name: "Checking", currency: "EUR", status: "active" } ])
    LunchflowItem.any_instance.stubs(:lunchflow_provider).returns(provider)
  end

  test "an internal return path is kept" do
    assert_equal "/accounts?tab=all", cancel_href_for("/accounts?tab=all")
  end

  test "an internal return path is kept without surrounding whitespace" do
    assert_equal "/accounts", cancel_href_for("  /accounts ")
  end

  test "a protocol-relative return path is rejected" do
    assert_equal new_account_path, cancel_href_for("//evil.example")
  end

  test "a triple-slash return path is rejected" do
    # URI.parse leaves host nil for ///host, so only the second-character check stops it.
    assert_equal new_account_path, cancel_href_for("///evil.example")
  end

  test "a backslash return path is rejected" do
    assert_equal new_account_path, cancel_href_for("/\\evil.example")
  end

  test "an encoded protocol-relative return path is rejected" do
    assert_equal new_account_path, cancel_href_for("/%2Fevil.example")
  end

  test "an encoded backslash return path is rejected" do
    assert_equal new_account_path, cancel_href_for("/%5Cevil.example")
  end

  test "a lowercase encoded protocol-relative return path is rejected" do
    assert_equal new_account_path, cancel_href_for("/%2fevil.example")
  end

  test "a return path with a control character after the slash is rejected" do
    assert_equal new_account_path, cancel_href_for("/\t/evil.example")
  end

  test "a bare slash is rejected" do
    assert_equal new_account_path, cancel_href_for("/")
  end

  test "an absolute URL is rejected" do
    assert_equal new_account_path, cancel_href_for("https://evil.example/accounts")
  end

  test "a backslash past the second character is rejected" do
    assert_equal new_account_path, cancel_href_for("/accounts\\evil.example")
  end

  test "a control character past the second character is rejected" do
    assert_equal new_account_path, cancel_href_for("/acc\tounts")
  end

  test "a malformed percent-encoding after the slash is rejected" do
    assert_equal new_account_path, cancel_href_for("/%zzevil.example")
  end

  test "a return path that does not route is rejected" do
    assert_equal new_account_path, cancel_href_for("/no-such-route-here")
  end

  test "a routable return path with a query string is kept" do
    assert_equal "/accounts?tab=manual", cancel_href_for("/accounts?tab=manual")
  end

  test "linking redirects to a rejected return path's fallback instead of off the site" do
    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_lunchflow_items_url, params: {
        account_id: accounts(:depository).id, lunchflow_account_id: "acc_1", return_to: "//evil.example"
      }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("lunchflow_items.link_existing_account.success", account_name: accounts(:depository).name), flash[:notice]
  end

  test "linking new accounts redirects to a rejected return path's fallback instead of off the site" do
    assert_difference "AccountProvider.count", 1 do
      post link_accounts_lunchflow_items_url, params: {
        account_ids: [ "acc_1" ], accountable_type: "Depository", return_to: "//evil.example"
      }
    end

    assert_redirected_to accounts_path
  end

  test "linking new accounts keeps an internal return path" do
    post link_accounts_lunchflow_items_url, params: {
      account_ids: [ "acc_1" ], accountable_type: "Depository", return_to: "/accounts?tab=all"
    }

    assert_redirected_to "/accounts?tab=all"
  end

  test "choosing an account to link drops a rejected return path from its cancel link and form" do
    get select_existing_account_lunchflow_items_url(account_id: accounts(:depository).id, return_to: "//evil.example")
    assert_response :success

    page = Nokogiri::HTML(response.body)
    assert_equal accounts_path, page.at_css("a[data-turbo-frame='_top']")["href"]
    assert_equal "", page.at_css("input[name='return_to']")["value"].to_s
  end

  private
    def cancel_href_for(return_to)
      get select_accounts_lunchflow_items_url(return_to: return_to)
      assert_response :success

      Nokogiri::HTML(response.body).at_css("a[data-turbo-frame='_top']")["href"]
    end
end
