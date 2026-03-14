class InactiveFamilyCleanerJob < ApplicationJob
  queue_as :scheduled

  BATCH_SIZE = 500
  ARCHIVE_EXPIRY = 90.days

  def perform(dry_run: false)
    return unless Rails.application.config.app_mode.managed?

    families = Family.inactive_trial_for_cleanup.limit(BATCH_SIZE)
    count = families.count

    if count == 0
      Rails.logger.info("InactiveFamilyCleanerJob: No inactive families to clean up")
      return
    end

    Rails.logger.info("InactiveFamilyCleanerJob: Found #{count} inactive families to clean up#{' (dry run)' if dry_run}")

    families.find_each do |family|
      if family.requires_data_archive?
        if dry_run
          Rails.logger.info("InactiveFamilyCleanerJob: Would archive data for family #{family.id}")
        else
          archive_family_data(family)
        end
      end

      if dry_run
        Rails.logger.info("InactiveFamilyCleanerJob: Would destroy family #{family.id} (created: #{family.created_at})")
      else
        Rails.logger.info("InactiveFamilyCleanerJob: Destroying family #{family.id} (created: #{family.created_at})")
        family.destroy
      end
    end

    Rails.logger.info("InactiveFamilyCleanerJob: Completed cleanup of #{count} families#{' (dry run)' if dry_run}")
  end

  private

    def archive_family_data(family)
      export_data = Family::DataExporter.new(family).generate_export
      email = family.users.order(:created_at).first&.email

      ActiveRecord::Base.transaction do
        archive = ArchivedExport.create!(
          email: email || "unknown",
          family_name: family.name,
          expires_at: ARCHIVE_EXPIRY.from_now
        )

        archive.export_file.attach(
          io: export_data,
          filename: "sure_archive_#{family.id}.zip",
          content_type: "application/zip"
        )

        raise ActiveRecord::Rollback, "File attach failed" unless archive.export_file.attached?

        Rails.logger.info("InactiveFamilyCleanerJob: Archived data for family #{family.id} (email: #{email}, token_digest: #{archive.download_token_digest.first(8)}...)")
      end
    end
end
