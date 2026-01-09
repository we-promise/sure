class DataCleanerJob < ApplicationJob
  queue_as :scheduled

  def perform
    clean_old_merchant_associations
  end

  private
    def clean_old_merchant_associations
      # Delete FamilyMerchantAssociation records older than 30 days
      deleted_count = FamilyMerchantAssociation
        .where(unlinked_at: ...30.days.ago)
        .delete_all

      Rails.logger.info("DataCleanerJob: Deleted #{deleted_count} old merchant associations") if deleted_count > 0
    end
end
