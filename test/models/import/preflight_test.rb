# frozen_string_literal: true

require "test_helper"

class Import::PreflightTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "SureImport preflight reports strict taxonomy collisions" do
    @family.tags.create!(name: "Reviewed", color: "#12B76A")
    ndjson = build_ndjson([
      { type: "Tag", data: { id: "tag-1", name: "Reviewed" } }
    ])

    assert_no_difference("Import.count") do
      response = Import::Preflight.new(
        family: @family,
        params: { type: "SureImport", raw_file_content: ndjson }
      ).call
      payload = response.payload[:data]

      assert_equal :ok, response.status
      assert_equal false, payload[:valid]
      assert_equal "existing_taxonomy_collision", payload[:errors].first[:code]
    end
  end

  test "SureImport preflight allows explicit taxonomy merge mode" do
    @family.tags.create!(name: "Reviewed", color: "#12B76A")
    ndjson = build_ndjson([
      { type: "Tag", data: { id: "tag-1", name: "Reviewed" } }
    ])

    response = Import::Preflight.new(
      family: @family,
      params: {
        type: "SureImport",
        raw_file_content: ndjson,
        merge_existing_taxonomy: true
      }
    ).call
    payload = response.payload[:data]

    assert_equal :ok, response.status
    assert_equal true, payload[:valid]
    assert_empty payload[:errors]
  end

  test "SureImport preflight counts invalid rows instead of validation errors" do
    ndjson = build_ndjson([
      [],
      { type: "Transaction", data: { id: "transaction-1" } }
    ])

    response = Import::Preflight.new(
      family: @family,
      params: { type: "SureImport", raw_file_content: ndjson }
    ).call
    payload = response.payload[:data]

    assert_equal :ok, response.status
    assert_equal 2, payload[:stats][:rows_count]
    assert_equal 1, payload[:stats][:valid_rows_count]
    assert_equal 1, payload[:stats][:invalid_rows_count]
    assert_operator payload[:errors].size, :>, payload[:stats][:invalid_rows_count]
  end

  private

    def build_ndjson(records)
      records.map(&:to_json).join("\n")
    end
end
