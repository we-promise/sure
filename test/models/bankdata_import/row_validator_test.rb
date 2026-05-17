# frozen_string_literal: true

require "test_helper"

class BankdataImport::RowValidatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @payload = bankdata_payload
  end

  test "requires source account mappings and transactions" do
    result = BankdataImport::RowValidator.new(family: @family, payload: {}).call

    assert_not result.valid?
    assert_includes result.errors, "source is required"
    assert_includes result.errors, "account_mappings is required"
    assert_includes result.errors, "transactions is required"
  end

  test "rejects invalid account mappings" do
    @payload["account_mappings"] = [ { "source_account_key" => "Betaal", "sure_account_id" => SecureRandom.uuid } ]

    result = BankdataImport::RowValidator.new(family: @family, payload: @payload).call

    assert_not result.valid?
    assert_includes result.errors, "account mapping Betaal does not reference an accessible account"
  end

  test "rejects duplicate external ids in one request" do
    @payload["transactions"][1]["external_id"] = @payload["transactions"][0]["external_id"]

    result = BankdataImport::RowValidator.new(family: @family, payload: @payload).call

    assert_not result.valid?
    assert_includes result.errors, "duplicate external_id #{@payload['transactions'][0]['external_id']}"
  end

  test "reports uncategorized rows without rejecting whole request by default" do
    @payload["transactions"][0]["category_name"] = nil

    result = BankdataImport::RowValidator.new(family: @family, payload: @payload).call

    assert result.valid?
    assert_equal "uncategorized", result.items.first[:status]
    assert_equal "category_name is required for import", result.items.first[:reason]
  end

  test "allows uncategorized rows when explicitly enabled" do
    @payload["allow_uncategorized"] = true
    @payload["transactions"][0]["category_name"] = nil
    @payload["transactions"][0]["category_parent_name"] = nil

    result = BankdataImport::RowValidator.new(family: @family, payload: @payload).call

    assert result.valid?
    assert_equal "ready", result.items.first[:status]
  end

  private

    def bankdata_payload
      JSON.parse(file_fixture("bankdata_import_payload.json").read).tap do |payload|
        payload["account_mappings"][0]["sure_account_id"] = @account.id
      end
    end
end
