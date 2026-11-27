# Retryable cleanup for an upload whose index status is already settled. It never re-indexes,
# so a storage failure here cannot repeat a provider upload or change the recorded result.
class VectorStore::PurgeDocumentFileJob < ApplicationJob
  queue_as { Ai::Routes.queue_for(:embed) }

  def perform(document)
    document.purge_file_if_settled
  end
end
