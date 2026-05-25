require "test_helper"

class FamilyResetJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @plaid_provider = mock
    Provider::Registry.stubs(:plaid_provider_for_region).returns(@plaid_provider)
  end

  test "resets family data successfully" do
    initial_account_count = @family.accounts.count
    initial_category_count = @family.categories.count
    import_session = @family.import_sessions.create!(expected_chunks: 1)
    import_session.imports.create!(
      family: @family,
      type: "SureImport",
      sequence: 1,
      checksum: "a" * 64
    )
    import_session.source_mappings.create!(
      family: @family,
      source_type: "Category",
      source_id: "source-category-1",
      target: @family.categories.first
    )

    # Family should have existing data
    assert initial_account_count > 0
    assert initial_category_count > 0
    assert_equal 1, @family.import_sessions.count
    assert_equal 1, @family.import_source_mappings.count

    # Don't expect Plaid removal calls since we're using fixtures without setup
    @plaid_provider.stubs(:remove_item)

    FamilyResetJob.perform_now(@family)

    # All data should be removed
    assert_equal 0, @family.accounts.reload.count
    assert_equal 0, @family.categories.reload.count
    assert_equal 0, @family.import_sessions.reload.count
    assert_equal 0, @family.import_source_mappings.reload.count
    assert_equal 0, @family.imports.reload.count
  end

  test "reset leaves another family's imports and mappings untouched" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en")
    other_category = other_family.categories.create!(name: "Other Category")
    other_session = other_family.import_sessions.create!(expected_chunks: 1)
    other_import = other_session.imports.create!(
      family: other_family,
      type: "SureImport",
      sequence: 1,
      checksum: "b" * 64
    )
    other_mapping = other_session.source_mappings.create!(
      family: other_family,
      source_type: "Category",
      source_id: "source-category-1",
      target: other_category
    )

    @family.import_sessions.create!(expected_chunks: 1)
    @plaid_provider.stubs(:remove_item)

    FamilyResetJob.perform_now(@family)

    assert ImportSession.exists?(other_session.id)
    assert Import.exists?(other_import.id)
    assert ImportSourceMapping.exists?(other_mapping.id)
    assert Category.exists?(other_category.id)
    assert_equal other_category, other_mapping.reload.target
  end

  test "resets family data even when Plaid credentials are invalid" do
    # Use existing plaid item from fixtures
    plaid_item = plaid_items(:one)
    assert_equal @family, plaid_item.family

    initial_plaid_count = @family.plaid_items.count
    assert initial_plaid_count > 0

    # Simulate invalid Plaid credentials error
    error_response = {
      "error_code" => "INVALID_API_KEYS",
      "error_message" => "invalid client_id or secret provided"
    }.to_json

    plaid_error = Plaid::ApiError.new(code: 400, response_body: error_response)
    @plaid_provider.expects(:remove_item).raises(plaid_error)

    # Job should complete successfully despite the Plaid error
    assert_nothing_raised do
      FamilyResetJob.perform_now(@family)
    end

    # PlaidItem should be deleted
    assert_equal 0, @family.plaid_items.reload.count
  end
end
