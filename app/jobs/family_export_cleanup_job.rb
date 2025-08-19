class FamilyExportCleanupJob < ApplicationJob
  queue_as :low_priority

  def perform(export_id, filename)
    # Note: The export record has already been destroyed at this point
    # We're just cleaning up any remaining files

    # Clean up any attached files (Active Storage)
    # This handles local filesystem cleanup automatically

    # If you're using external storage (S3, etc.), you might need additional cleanup here
    # Example for S3:
    # s3_client = Aws::S3::Client.new
    # s3_client.delete_object(bucket: ENV['AWS_S3_BUCKET'], key: "exports/#{filename}")

    # For now, we'll just log the cleanup attempt
    # The actual file cleanup is handled by Active Storage when the record is destroyed
    Rails.logger.info "Export cleanup completed for #{filename} (ID: #{export_id})"
  rescue => e
    Rails.logger.error "Export cleanup failed for #{filename} (ID: #{export_id}): #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    # You might want to retry this job or notify administrators
    # raise e # Uncomment to retry the job
  end
end
