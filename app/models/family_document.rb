class FamilyDocument < ApplicationRecord
  belongs_to :family
  belongs_to :family_document_store, class_name: "Family::DocumentStore", optional: true

  has_one_attached :file

  SUPPORTED_EXTENSIONS = VectorStore::Base::SUPPORTED_EXTENSIONS

  validate :document_store_belongs_to_family
  validate :store_binding_cannot_change, on: :update

  validates :filename, presence: true
  validates :status, inclusion: { in: %w[pending processing ready error] }

  scope :ready, -> { where(status: "ready") }

  def mark_ready!
    update!(status: "ready")
  end

  def mark_error!(error_message = nil)
    update!(status: "error", metadata: (metadata || {}).merge("error" => error_message))
  end

  def supported_extension?
    ext = File.extname(filename).downcase
    SUPPORTED_EXTENSIONS.include?(ext)
  end

  private
    def document_store_belongs_to_family
      if family_document_store && family_document_store.family_id != family_id
        errors.add(:family_document_store, "must belong to the same family")
      end
    end

    def store_binding_cannot_change
      if will_save_change_to_family_id? || will_save_change_to_family_document_store_id? || will_save_change_to_provider_file_id?
        errors.add(:base, "Document store binding cannot change")
      end
    end
end
