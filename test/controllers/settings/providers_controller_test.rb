require "test_helper"

class Settings::ProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)

    # Ensure provider adapters are loaded for all tests
    Provider::Factory.ensure_adapters_loaded
  end

  test "can access when self hosting is disabled (managed mode)" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get settings_providers_url
    assert_response :success

    patch settings_providers_url, params: { setting: { plaid_client_id: "test123" } }
    assert_redirected_to settings_providers_url
  end

  test "should get show when self hosting is enabled" do
    with_self_hosting do
      get settings_providers_url
      assert_response :success
    end
  end

  test "correctly identifies declared vs dynamic fields" do
    # All current provider fields are dynamic, but the logic should correctly
    # distinguish between declared and dynamic fields
    with_self_hosting do
      # plaid_client_id is a dynamic field (not defined in Setting)
      refute Setting.singleton_class.method_defined?(:plaid_client_id=),
        "plaid_client_id= should NOT be defined on Setting's singleton class"

      # openai_model IS a declared field (defined in Setting)
      # but it's not a provider field, so it won't go through this controller
      assert Setting.singleton_class.method_defined?(:openai_model=),
        "openai_model= should be defined on Setting's singleton class"
    end
  end

  test "updates dynamic provider fields using batch update" do
    # plaid_client_id is a dynamic field, stored as an individual entry
    with_self_hosting do
      # Clear any existing plaid settings
      Setting["plaid_client_id"] = nil

      patch settings_providers_url, params: {
        setting: { plaid_client_id: "test_client_id" }
      }

      assert_redirected_to settings_providers_url
      assert_equal "test_client_id", Setting["plaid_client_id"]
    end
  end

  test "batches multiple dynamic fields from same provider atomically" do
    # Test that multiple fields from Plaid are updated as individual entries
    with_self_hosting do
      # Clear existing fields
      Setting["plaid_client_id"] = nil
      Setting["plaid_secret"] = nil
      Setting["plaid_environment"] = nil

      patch settings_providers_url, params: {
        setting: {
          plaid_client_id: "new_client_id",
          plaid_secret: "new_secret",
          plaid_environment: "production"
        }
      }

      assert_redirected_to settings_providers_url

      # All three should be present as individual entries
      assert_equal "new_client_id", Setting["plaid_client_id"]
      assert_equal "new_secret", Setting["plaid_secret"]
      assert_equal "production", Setting["plaid_environment"]
    end
  end

  test "batches dynamic fields from multiple providers atomically" do
    # Test that fields from different providers are stored as individual entries
    with_self_hosting do
      # Clear existing fields
      Setting["plaid_client_id"] = nil
      Setting["plaid_secret"] = nil
      Setting["plaid_eu_client_id"] = nil
      Setting["plaid_eu_secret"] = nil

      patch settings_providers_url, params: {
        setting: {
          plaid_client_id: "plaid_client",
          plaid_secret: "plaid_secret",
          plaid_eu_client_id: "plaid_eu_client",
          plaid_eu_secret: "plaid_eu_secret"
        }
      }

      assert_redirected_to settings_providers_url

      # All fields should be present
      assert_equal "plaid_client", Setting["plaid_client_id"]
      assert_equal "plaid_secret", Setting["plaid_secret"]
      assert_equal "plaid_eu_client", Setting["plaid_eu_client_id"]
      assert_equal "plaid_eu_secret", Setting["plaid_eu_secret"]
    end
  end

  test "preserves existing dynamic fields when updating new ones" do
    # Test that updating some fields doesn't overwrite other existing fields
    with_self_hosting do
      # Set initial fields
      Setting["existing_field_1"] = "value1"
      Setting["plaid_client_id"] = "old_client_id"

      # Update one field and add a new one
      patch settings_providers_url, params: {
        setting: {
          plaid_client_id: "new_client_id",
          plaid_secret: "new_secret"
        }
      }

      assert_redirected_to settings_providers_url

      # Existing unrelated field should still be there
      assert_equal "value1", Setting["existing_field_1"]

      # Updated field should have new value
      assert_equal "new_client_id", Setting["plaid_client_id"]

      # New field should be added
      assert_equal "new_secret", Setting["plaid_secret"]
    end
  end

  test "skips placeholder values for secret fields" do
    with_self_hosting do
      # Set an initial secret value
      Setting["plaid_secret"] = "real_secret"

      # Try to update with placeholder
      patch settings_providers_url, params: {
        setting: {
          plaid_client_id: "new_client_id",
          plaid_secret: "********"  # Placeholder value
        }
      }

      assert_redirected_to settings_providers_url

      # Client ID should be updated
      assert_equal "new_client_id", Setting["plaid_client_id"]

      # Secret should remain unchanged
      assert_equal "real_secret", Setting["plaid_secret"]
    end
  end

  test "converts blank values to nil and removes from dynamic_fields" do
    with_self_hosting do
      # Set initial values
      Setting["plaid_client_id"] = "old_value"
      assert_equal "old_value", Setting["plaid_client_id"]
      assert Setting.key?("plaid_client_id")

      patch settings_providers_url, params: {
        setting: { plaid_client_id: "  " }  # Blank string with spaces
      }

      assert_redirected_to settings_providers_url
      assert_nil Setting["plaid_client_id"]
      # Entry should be removed, not just set to nil
      refute Setting.key?("plaid_client_id"),
        "nil values should delete the entry"
    end
  end

  test "handles sequential updates to different dynamic fields safely" do
    # This test simulates what would happen if two requests tried to update
    # different dynamic fields sequentially. With individual entries,
    # all changes should be preserved without conflicts.
    with_self_hosting do
      Setting["existing_field"] = "existing_value"

      # Simulate first request updating plaid fields
      patch settings_providers_url, params: {
        setting: {
          plaid_client_id: "client_id_1",
          plaid_secret: "secret_1"
        }
      }

      # Existing field should still be there
      assert_equal "existing_value", Setting["existing_field"]

      # New fields should be added
      assert_equal "client_id_1", Setting["plaid_client_id"]
      assert_equal "secret_1", Setting["plaid_secret"]

      # Simulate second request updating different plaid fields
      patch settings_providers_url, params: {
        setting: {
          plaid_environment: "production"
        }
      }

      # All previously set fields should still be there
      assert_equal "existing_value", Setting["existing_field"]
      assert_equal "client_id_1", Setting["plaid_client_id"]
      assert_equal "secret_1", Setting["plaid_secret"]
      assert_equal "production", Setting["plaid_environment"]
    end
  end

  test "only processes valid configuration fields" do
    with_self_hosting do
      # Try to update a field that doesn't exist in any provider configuration
      patch settings_providers_url, params: {
        setting: {
          plaid_client_id: "valid_field",
          fake_field_that_does_not_exist: "should_be_ignored"
        }
      }

      assert_redirected_to settings_providers_url

      # Valid field should be updated
      assert_equal "valid_field", Setting["plaid_client_id"]

      # Invalid field should not be stored
      assert_nil Setting["fake_field_that_does_not_exist"]
    end
  end

  test "calls reload_configuration on updated providers" do
    with_self_hosting do
      # Mock the adapter class to verify reload_configuration is called
      Provider::PlaidAdapter.expects(:reload_configuration).once

      patch settings_providers_url, params: {
        setting: { plaid_client_id: "new_client_id" }
      }

      assert_redirected_to settings_providers_url
    end
  end

  test "reloads configuration for multiple providers when updated" do
    with_self_hosting do
      # Both Plaid providers (US and EU) should have their configuration reloaded
      Provider::PlaidAdapter.expects(:reload_configuration).once
      Provider::PlaidEuAdapter.expects(:reload_configuration).once

      patch settings_providers_url, params: {
        setting: {
          plaid_client_id: "plaid_client",
          plaid_eu_client_id: "plaid_eu_client"
        }
      }

      assert_redirected_to settings_providers_url
    end
  end

  test "logs errors when update fails" do
    with_self_hosting do
      # Test that errors during update are properly logged and handled gracefully
      # We'll force an error by making the []= method raise
      Setting.expects(:[]=).with("plaid_client_id", "test").raises(StandardError.new("Database error")).once

      # Mock logger to verify error is logged
      Rails.logger.expects(:error).with(regexp_matches(/Failed to update provider settings.*Database error/)).once

      patch settings_providers_url, params: {
        setting: { plaid_client_id: "test" }
      }

      # Controller should handle the error gracefully
      assert_response :unprocessable_entity
      assert_equal "Failed to update provider settings: Database error", flash[:alert]
    end
  end

  test "shows no changes message when no fields are updated" do
    with_self_hosting do
      # Only send a secret field with placeholder value (which gets skipped)
      Setting["plaid_secret"] = "existing_secret"

      patch settings_providers_url, params: {
        setting: { plaid_secret: "********" }
      }

      assert_redirected_to settings_providers_url
      assert_equal "No changes were made", flash[:notice]
    end
  end

  test "non-admin users cannot update providers" do
    with_self_hosting do
      sign_in users(:family_member)

      patch settings_providers_url, params: {
        setting: { plaid_client_id: "test" }
      }

      assert_redirected_to settings_providers_path
      assert_equal "Not authorized", flash[:alert]

      # Value should not have changed
      assert_nil Setting["plaid_client_id"]
    end
  end

  test "uses singleton_class method_defined to detect declared fields" do
    with_self_hosting do
      # This test verifies the difference between respond_to? and singleton_class.method_defined?

      # openai_model is a declared field
      assert Setting.singleton_class.method_defined?(:openai_model=),
        "openai_model= should be defined on Setting's singleton class"
      assert Setting.respond_to?(:openai_model=),
        "respond_to? should return true for declared field"

      # plaid_client_id is a dynamic field
      refute Setting.singleton_class.method_defined?(:plaid_client_id=),
        "plaid_client_id= should NOT be defined on Setting's singleton class"
      refute Setting.respond_to?(:plaid_client_id=),
        "respond_to? should return false for dynamic field"

      # Both methods currently return the same result, but singleton_class.method_defined?
      # is more explicit and reliable for checking if a method is actually defined
    end
  end
end
