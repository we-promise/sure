# Module for providers that support syncing with external services
# Include this module in your adapter if the provider supports sync operations
module Provider::Syncable
  extend ActiveSupport::Concern

  # Returns the path to sync this provider's item
  # @return [String] The sync path
  def sync_path
    raise NotImplementedError, "#{self.class} must implement #sync_path"
  end

  # Returns the provider's item/connection object
  # @return [Object] The item object (e.g., PlaidItem, SimplefinItem)
  def item
    raise NotImplementedError, "#{self.class} must implement #item"
  end

  # Check if the item is currently syncing
  # @return [Boolean] True if syncing, false otherwise
  def syncing?
    item&.syncing? || false
  end

  # Returns the current sync status
  # @return [String, nil] The status string or nil
  def status
    item&.status
  end

  # Check if the item requires an update (e.g., re-authentication)
  # @return [Boolean] True if update required, false otherwise
  def requires_update?
    status == "requires_update"
  end
end
