# Enrichable models can have 1+ of their fields enriched by various
# external sources (i.e. Plaid) or internal sources (i.e. Rules)
#
# This module defines how models should, lock, unlock, and edit attributes
# based on the source of the edit.  User edits always take highest precedence.
#
# For example:
#
# If a Rule tells us to set the category to "Groceries", but the user later overrides
# a transaction with a category of "Food", we should not override the category again.
#
module Enrichable
  extend ActiveSupport::Concern

  InvalidAttributeError = Class.new(StandardError)

  included do
    has_many :data_enrichments, as: :enrichable, dependent: :destroy

    scope :enrichable, ->(attrs) {
      attrs = Array(attrs).map(&:to_s)
      json_condition = attrs.each_with_object({}) { |attr, hash| hash[attr] = true }
      where.not(Arel.sql("#{table_name}.locked_attributes ?| array[:keys]"), keys: attrs)
    }
  end

  class_methods do
    # Clear AI-sourced locked attributes for all records
    def clear_ai_cache
      transaction do
        # Find all AI enrichments for this model
        ai_enrichments = DataEnrichment.where(enrichable_type: name, source: "ai")

        # Get all enrichable_ids and load records in one query
        enrichable_ids = ai_enrichments.distinct.pluck(:enrichable_id)
        records = where(id: enrichable_ids).index_by(&:id)
        enrichments_by_id = ai_enrichments.group_by(&:enrichable_id)

        enrichments_by_id.each do |enrichable_id, enrichments|
          record = records[enrichable_id]
          next unless record

          # Unlock all AI-locked attributes
          new_locked_attributes = record.locked_attributes.dup
          enrichments.each do |enrichment|
            new_locked_attributes.delete(enrichment.attribute_name)
          end

          record.update_column(:locked_attributes, new_locked_attributes)
        end

        # Delete all AI enrichment records
        ai_enrichments.delete_all
      end
    end
  end

  # Convenience method for a single attribute
  def enrich_attribute(attr, value, source:, metadata: {})
    enrich_attributes({ attr => value }, source:, metadata:)
  end

  # Enriches and logs all attributes that:
  # - Are not locked
  # - Are not ignored
  # - Have changed value from the last saved value
  def enrich_attributes(attrs, source:, metadata: {})
    enrichable_attrs = Array(attrs).reject do |attr_key, attr_value|
      locked?(attr_key) || ignored_enrichable_attributes.include?(attr_key) || self[attr_key.to_s] == attr_value
    end

    ActiveRecord::Base.transaction do
      enrichable_attrs.each do |attr, value|
        self.send("#{attr}=", value)

        # If it's a new record, this isn't technically an "enrichment".  No logging necessary.
        unless self.new_record?
          log_enrichment(attribute_name: attr, attribute_value: value, source: source, metadata: metadata)
        end
      end

      save
    end
  end

  def locked?(attr)
    locked_attributes[attr.to_s].present?
  end

  def enrichable?(attr)
    !locked?(attr)
  end

  def lock_attr!(attr)
    update!(locked_attributes: locked_attributes.merge(attr.to_s => Time.current))
  end

  def unlock_attr!(attr)
    update!(locked_attributes: locked_attributes.except(attr.to_s))
  end

  def lock_saved_attributes!
    saved_changes.keys.reject { |attr| ignored_enrichable_attributes.include?(attr) }.each do |attr|
      lock_attr!(attr)
    end
  end

  # Clear AI-sourced locked attributes for this record
  def clear_ai_cache
    self.class.transaction do
      # Find all AI enrichments for this record
      ai_enrichments = data_enrichments.where(source: "ai")

      # Unlock all AI-locked attributes
      new_locked_attributes = locked_attributes.dup
      ai_enrichments.each do |enrichment|
        new_locked_attributes.delete(enrichment.attribute_name)
      end

      update_column(:locked_attributes, new_locked_attributes)

      # Delete all AI enrichment records
      ai_enrichments.delete_all
    end
  end

  private
    def log_enrichment(attribute_name:, attribute_value:, source:, metadata: {})
      de = DataEnrichment.find_or_create_by(
        enrichable: self,
        attribute_name: attribute_name,
        source: source,
      )

      de.value = attribute_value
      de.metadata = metadata
      de.save
    end

    def ignored_enrichable_attributes
      %w[id updated_at created_at]
    end
end
