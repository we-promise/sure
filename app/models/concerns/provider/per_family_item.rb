# Concern for provider item models that store per-family credentials
#
# This concern provides helper methods and accessors for per-family provider items.
# It connects the model to its adapter configuration for metadata access.
#
# Example usage in a model:
#   class LunchflowItem < ApplicationRecord
#     include Provider::PerFamilyItem
#
#     belongs_to :family
#
#     # Manual setup (required):
#     if Rails.application.credentials.active_record_encryption.present?
#       encrypts :api_key, deterministic: true
#     end
#
#     validates :api_key, presence: true
#
#     def credentials_configured?
#       api_key.present?
#     end
#
#     def effective_base_url
#       base_url.presence || "https://lunchflow.app/api/v1"
#     end
#   end
#
# The concern provides:
# - Access to the adapter's per-family configuration
# - Helper methods for working with configuration metadata
module Provider::PerFamilyItem
  extend ActiveSupport::Concern

  class_methods do
    # Find the adapter class for this model
    def adapter_class
      adapter_name = "Provider::#{name.gsub(/Item$/, "")}Adapter"
      adapter_name.constantize
    rescue NameError
      nil
    end

    # Get the per-family configuration for this model
    def per_family_configuration
      adapter_class&.per_family_configuration
    end

    # Get the provider key for this model (e.g., "lunchflow")
    def provider_key
      name.gsub(/Item$/, "").underscore
    end
  end

  # Instance methods

  # Get the adapter class
  def adapter_class
    self.class.adapter_class
  end

  # Get the per-family configuration
  def per_family_configuration
    self.class.per_family_configuration
  end

  # Get the provider key
  def provider_key
    self.class.provider_key
  end
end
