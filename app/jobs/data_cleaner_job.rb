class DataCleanerJob < ApplicationJob
  queue_as :scheduled

  def perform
    clean_old_merchant_associations
    clean_expired_archived_exports
  end

  private
    def clean_old_merchant_associations
      # Delete FamilyMerchantAssociation records older than 30 days
      deleted_count = FamilyMerchantAssociation
        .where(unlinked_at: ...30.days.ago)
        .delete_all

      Rails.logger.info("DataCleanerJob: Deleted #{deleted_count} old merchant associations") if deleted_count > 0
    end

    def clean_expired_archived_exports
      deleted_count = ArchivedExport.expired.destroy_all.count

      Rails.logger.info("DataCleanerJob: Deleted #{deleted_count} expired archived exports") if deleted_count > 0
    end
end
