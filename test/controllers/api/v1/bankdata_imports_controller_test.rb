# frozen_string_literal: true

require "test_helper"

class Api::V1::BankdataImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(user: @user, name: "BankData Key", scopes: [ "read_write" ], display_key: "bankdata_#{SecureRandom.hex(8)}")
    @payload = bankdata_payload
    ApiRateLimiter.stubs(:limit).returns(NoopApiRateLimiter.new(@api_key))
  end

  test "preview success does not create transactions" do
    assert_no_difference "Entry.count" do
      post "/api/v1/bankdata/imports/preview", params: @payload.to_json, headers: api_headers(@api_key).merge("CONTENT_TYPE" => "application/json")
      assert_response :success
    end

    assert_equal 6, JSON.parse(response.body)["created"]
  end

  test "import success creates transactions" do
    assert_difference "Entry.count", 6 do
      post "/api/v1/bankdata/imports", params: @payload.to_json, headers: api_headers(@api_key).merge("CONTENT_TYPE" => "application/json")
      assert_response :created
    end
  end

  test "unauthorized requests are rejected" do
    post "/api/v1/bankdata/imports/preview", params: @payload.to_json, headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :unauthorized
  end

  test "validation errors return unprocessable entity" do
    @payload.delete("source")

    post "/api/v1/bankdata/imports", params: @payload.to_json, headers: api_headers(@api_key).merge("CONTENT_TYPE" => "application/json")

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["errors"], "source is required"
  end

  test "preview returns per row reasons and reconciliation totals" do
    @payload["transactions"].first["category_name"] = nil

    post "/api/v1/bankdata/imports/preview", params: @payload.to_json, headers: api_headers(@api_key).merge("CONTENT_TYPE" => "application/json")

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 6, body["total"]
    assert_equal 5, body["created"]
    assert_equal 1, body["uncategorized"]
    assert_equal "category_name is required for import", body["items"].first["reason"]
    assert_equal "192.10", body["expense_total"]
  end

  test "second import is idempotent and preserves existing transactions" do
    post "/api/v1/bankdata/imports", params: @payload.to_json, headers: api_headers(@api_key).merge("CONTENT_TYPE" => "application/json")
    entry = Entry.find_by!(source: "bankdata_pipeline", external_id: @payload["transactions"].first["external_id"])
    entry.update!(name: "Edited in Sure")

    assert_no_difference "Entry.count" do
      post "/api/v1/bankdata/imports", params: @payload.to_json, headers: api_headers(@api_key).merge("CONTENT_TYPE" => "application/json")
      assert_response :created
    end

    body = JSON.parse(response.body)
    assert_equal 0, body["created"]
    assert_equal 6, body["already_imported"]
    assert_equal "Edited in Sure", entry.reload.name
  end

  test "import response includes uncategorized summary count" do
    payload = JSON.parse(file_fixture("bankdata_import_uncategorized_payload.json").read)
    payload["account_mappings"][0]["sure_account_id"] = @account.id

    post "/api/v1/bankdata/imports", params: payload.to_json, headers: api_headers(@api_key).merge("CONTENT_TYPE" => "application/json")

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 1, body["uncategorized"]
  end

  private

    def bankdata_payload
      JSON.parse(file_fixture("bankdata_import_payload.json").read).tap do |payload|
        payload["account_mappings"][0]["sure_account_id"] = @account.id
      end
    end
end
