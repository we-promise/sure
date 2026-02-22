require "test_helper"

class RetirementControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @family = @user.family
  end

  test "show redirects to setup when no config exists" do
    @family.retirement_config&.destroy
    get retirement_path
    assert_redirected_to setup_retirement_path
  end

  test "show renders successfully when config exists" do
    # Ensure config exists
    @family.create_retirement_config!(
      birth_year: 1990,
      retirement_age: 67,
      target_monthly_income: 3000,
      currency: "EUR"
    ) unless @family.retirement_config

    get retirement_path
    assert_response :ok
  end

  test "setup renders successfully" do
    get setup_retirement_path
    assert_response :ok
  end

  test "create saves retirement config" do
    @family.retirement_config&.destroy

    assert_difference "RetirementConfig.count", 1 do
      post retirement_path, params: {
        retirement_config: {
          birth_year: 1990,
          retirement_age: 67,
          target_monthly_income: 3000,
          currency: "EUR",
          pension_system: "de_grv",
          country: "DE",
          expected_return_pct: 7.0,
          inflation_pct: 2.0,
          tax_rate_pct: 26.38
        }
      }
    end

    assert_redirected_to retirement_path
  end

  test "edit renders successfully" do
    @family.create_retirement_config!(
      birth_year: 1990,
      retirement_age: 67,
      target_monthly_income: 3000,
      currency: "EUR"
    ) unless @family.retirement_config

    get edit_retirement_path
    assert_response :ok
  end

  test "update modifies retirement config" do
    config = @family.retirement_config || @family.create_retirement_config!(
      birth_year: 1990,
      retirement_age: 67,
      target_monthly_income: 3000,
      currency: "EUR"
    )

    patch retirement_path, params: {
      retirement_config: {
        target_monthly_income: 4000
      }
    }

    assert_redirected_to retirement_path
    config.reload
    assert_equal 4000, config.target_monthly_income.to_i
  end

  test "add_pension_entry creates new entry" do
    config = @family.retirement_config || @family.create_retirement_config!(
      birth_year: 1990,
      retirement_age: 67,
      target_monthly_income: 3000,
      currency: "EUR"
    )

    assert_difference "PensionEntry.count", 1 do
      post add_pension_entry_retirement_path, params: {
        pension_entry: {
          recorded_at: "2025-01-15",
          current_points: 10.5,
          current_monthly_pension: 400.0,
          projected_monthly_pension: 1900.0,
          notes: "Test entry"
        }
      }
    end

    assert_redirected_to retirement_path
  end

  test "destroy_pension_entry removes entry" do
    config = @family.retirement_config || @family.create_retirement_config!(
      birth_year: 1990,
      retirement_age: 67,
      target_monthly_income: 3000,
      currency: "EUR"
    )

    entry = config.pension_entries.create!(
      recorded_at: "2025-06-01",
      current_points: 11.0
    )

    assert_difference "PensionEntry.count", -1 do
      delete destroy_pension_entry_retirement_path(id: entry.id)
    end

    assert_redirected_to retirement_path
  end

  test "destroy_pension_entry cannot delete another family's entry" do
    # Create config and entry for the current user's family
    config = @family.retirement_config || @family.create_retirement_config!(
      birth_year: 1990,
      retirement_age: 67,
      target_monthly_income: 3000,
      currency: "EUR"
    )
    own_entry = config.pension_entries.create!(
      recorded_at: "2025-06-01",
      current_points: 11.0
    )

    # Create config and entry for a different family
    other_family = families(:empty)
    other_config = other_family.retirement_config || other_family.create_retirement_config!(
      birth_year: 1985,
      retirement_age: 65,
      target_monthly_income: 2500,
      currency: "EUR"
    )
    other_entry = other_config.pension_entries.create!(
      recorded_at: "2025-06-01",
      current_points: 8.0
    )

    # Attempting to delete another family's entry should return 404
    assert_no_difference "PensionEntry.count" do
      delete destroy_pension_entry_retirement_path(id: other_entry.id)
    end

    assert_response :not_found

    # The other family's entry should still exist
    assert PensionEntry.exists?(other_entry.id)
  end
end
