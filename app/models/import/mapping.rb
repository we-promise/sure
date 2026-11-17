class Import::Mapping < ApplicationRecord
  CREATE_NEW_KEY = "internal_new_resource"

  belongs_to :import
  belongs_to :mappable, polymorphic: true, optional: true

  validates :key, presence: true, uniqueness: { scope: [ :import_id, :type ] }, allow_blank: true

  scope :for_import, ->(import) { where(import: import) }
  scope :creational, -> { where(create_when_empty: true, mappable: nil) }
  scope :categories, -> { where(type: "Import::CategoryMapping") }
  scope :tags, -> { where(type: "Import::TagMapping") }
  scope :accounts, -> { where(type: "Import::AccountMapping") }
  scope :account_types, -> { where(type: "Import::AccountTypeMapping") }
  scope :securities, -> { where(type: "Import::SecurityMapping") }

  class << self
    def mappable_for(key)
      find_by(key: key)&.mappable
    end

    def mappables_by_key(import)
      raise NotImplementedError, "Subclass must implement mappables_by_key"
    end
  end

  def selectable_values
    raise NotImplementedError, "Subclass must implement selectable_values"
  end

  def values_count
    raise NotImplementedError, "Subclass must implement values_count"
  end

  def mappable_class
    nil
  end

  # The mappable to persist during Import#sync_mappings, given the value freshly
  # derived from the CSV. Most mappings re-derive on every sync, so the derived
  # value wins. Subclasses holding a user-chosen mappable (not re-derivable from
  # the CSV) override this to preserve the existing selection.
  def mappable_for_sync(derived_mappable)
    derived_mappable
  end

  def creatable?
    mappable.nil? && key.present? && create_when_empty
  end

  def create_mappable!
    raise NotImplementedError, "Subclass must implement create_mappable!"
  end
end
