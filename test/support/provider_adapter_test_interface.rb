# Shared test interface for all provider adapters
# Include this module in your provider adapter test to ensure it implements the required interface
#
# Usage:
#   class Provider::AcmeAdapterTest < ActiveSupport::TestCase
#     include ProviderAdapterTestInterface
#
#     setup do
#       @adapter = Provider::AcmeAdapter.new(...)
#     end
#
#     def adapter
#       @adapter
#     end
#
#     test_provider_adapter_interface
#   end
module ProviderAdapterTestInterface
  extend ActiveSupport::Concern

  class_methods do
    # Tests the core provider adapter interface
    # Call this method in your test class to run all interface tests
    def test_provider_adapter_interface
      test "adapter implements provider_name" do
        assert_respond_to adapter, :provider_name
        assert_kind_of String, adapter.provider_name
        assert adapter.provider_name.present?, "provider_name should not be blank"
      end

      test "adapter implements provider_type" do
        assert_respond_to adapter, :provider_type
        assert_kind_of String, adapter.provider_type
        assert adapter.provider_type.present?, "provider_type should not be blank"
      end

      test "adapter implements can_delete_holdings?" do
        assert_respond_to adapter, :can_delete_holdings?
        assert_includes [ true, false ], adapter.can_delete_holdings?
      end

      test "adapter implements metadata" do
        assert_respond_to adapter, :metadata
        metadata = adapter.metadata

        assert_kind_of Hash, metadata
        assert_includes metadata.keys, :provider_name
        assert_includes metadata.keys, :provider_type

        assert_equal adapter.provider_name, metadata[:provider_name]
        assert_equal adapter.provider_type, metadata[:provider_type]
      end

      test "adapter implements raw_payload" do
        assert_respond_to adapter, :raw_payload
        # raw_payload can be nil or a Hash
        assert adapter.raw_payload.nil? || adapter.raw_payload.is_a?(Hash)
      end

      test "adapter is registered with factory" do
        provider_type = adapter.provider_type
        assert_includes Provider::Factory.registered_provider_types, provider_type,
          "#{provider_type} should be registered with Provider::Factory"
      end
    end

    # Tests for adapters that include Provider::Syncable
    def test_syncable_interface
      test "syncable adapter implements sync_path" do
        assert_respond_to adapter, :sync_path
        assert_kind_of String, adapter.sync_path
        assert adapter.sync_path.present?, "sync_path should not be blank"
      end

      test "syncable adapter implements item" do
        assert_respond_to adapter, :item
        assert_not_nil adapter.item, "item should not be nil for syncable providers"
      end

      test "syncable adapter implements syncing?" do
        assert_respond_to adapter, :syncing?
        assert_includes [ true, false ], adapter.syncing?
      end

      test "syncable adapter implements status" do
        assert_respond_to adapter, :status
        # status can be nil or a String
        assert adapter.status.nil? || adapter.status.is_a?(String)
      end

      test "syncable adapter implements requires_update?" do
        assert_respond_to adapter, :requires_update?
        assert_includes [ true, false ], adapter.requires_update?
      end
    end

    # Tests for adapters that include Provider::InstitutionMetadata
    def test_institution_metadata_interface
      test "institution metadata adapter implements institution_domain" do
        assert_respond_to adapter, :institution_domain
        # Can be nil or String
        assert adapter.institution_domain.nil? || adapter.institution_domain.is_a?(String)
      end

      test "institution metadata adapter implements institution_name" do
        assert_respond_to adapter, :institution_name
        # Can be nil or String
        assert adapter.institution_name.nil? || adapter.institution_name.is_a?(String)
      end

      test "institution metadata adapter implements institution_url" do
        assert_respond_to adapter, :institution_url
        # Can be nil or String
        assert adapter.institution_url.nil? || adapter.institution_url.is_a?(String)
      end

      test "institution metadata adapter implements institution_color" do
        assert_respond_to adapter, :institution_color
        # Can be nil or String
        assert adapter.institution_color.nil? || adapter.institution_color.is_a?(String)
      end

      test "institution metadata adapter implements institution_metadata" do
        assert_respond_to adapter, :institution_metadata
        metadata = adapter.institution_metadata

        assert_kind_of Hash, metadata
        # Metadata should only contain non-nil values
        metadata.each do |key, value|
          assert_not_nil value, "#{key} in institution_metadata should not be nil (it should be omitted instead)"
        end
      end
    end
  end

  # Override this method in your test to provide the adapter instance
  def adapter
    raise NotImplementedError, "Test must implement #adapter method"
  end
end
