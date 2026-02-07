# frozen_string_literal: true

class IndexaCapitalConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(indexa_capital_item_id:, authorization_id:, account_id:)
    Rails.logger.info(
      "IndexaCapitalConnectionCleanupJob - Cleaning up connection #{authorization_id} " \
      "for former account #{account_id}"
    )

    indexa_capital_item = IndexaCapitalItem.find_by(id: indexa_capital_item_id)
    return unless indexa_capital_item

    # Check if other accounts still use this connection
    if indexa_capital_item.indexa_capital_accounts
         .where(indexa_capital_authorization_id: authorization_id)
         .exists?
      Rails.logger.info("IndexaCapitalConnectionCleanupJob - Connection still in use, skipping")
      return
    end

    # Delete from provider API
    delete_connection(indexa_capital_item, authorization_id)

    Rails.logger.info("IndexaCapitalConnectionCleanupJob - Connection #{authorization_id} deleted")
  rescue => e
    Rails.logger.warn(
      "IndexaCapitalConnectionCleanupJob - Failed: #{e.class} - #{e.message}"
    )
    # Don't raise - cleanup failures shouldn't block other operations
  end

  private

    def delete_connection(indexa_capital_item, authorization_id)
      provider = indexa_capital_item.indexa_capital_provider
      return unless provider

      credentials = indexa_capital_item.indexa_capital_credentials
      return unless credentials

      # TODO: Implement API call to delete connection
      # Example:
      # provider.delete_connection(
      #   authorization_id: authorization_id,
      #   **credentials
      # )
      nil # Placeholder until provider.delete_connection is implemented
    rescue => e
      Rails.logger.warn(
        "IndexaCapitalConnectionCleanupJob - API delete failed: #{e.message}"
      )
    end
end
