class ImportSourceMapping < ApplicationRecord
  belongs_to :family
  belongs_to :import_session
  belongs_to :target, polymorphic: true

  validates :source_type, :source_id, :target_type, :target_id, presence: true
  validates :source_type, length: { maximum: 64 }
  validates :source_id, length: { maximum: 255 }
  validates :source_id, uniqueness: { scope: [ :import_session_id, :source_type ] }
end
