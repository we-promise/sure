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
    # Override in models to define family-scoped query
    def family_scope(family)
      none
    end

    def clear_ai_cache(family)
      count = 0
      family_scope(family).find_each do |record|
        record.clear_ai_cache
        count += 1
      end
      count
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
  # Returns true if any attributes were actually changed, false otherwise
  def enrich_attributes(attrs, source:, metadata: {})
    # Track current values before modification for virtual attributes (like tag_ids)
    current_values = {}
    enrichable_attrs = Array(attrs).reject do |attr_key, attr_value|
      if locked?(attr_key) || ignored_enrichable_attributes.include?(attr_key)
        true
      else
        # For virtual attributes (like tag_ids), use the getter method
        # For regular attributes, use self[attr_key]
        current_value = if respond_to?(attr_key.to_sym)
          send(attr_key.to_sym)
        else
          self[attr_key.to_s]
        end

        # Normalize arrays for comparison (sort them)
        if current_value.is_a?(Array) && attr_value.is_a?(Array)
          current_values[attr_key] = current_value
          current_value.sort == attr_value.sort
        else
          current_values[attr_key] = current_value
          current_value == attr_value
        end
      end
    end

    return false if enrichable_attrs.empty?

    was_modified = false
    ActiveRecord::Base.transaction do
      enrichable_attrs.each do |attr, value|
        self.send("#{attr}=", value)

        # If it's a new record, this isn't technically an "enrichment".  No logging necessary.
        unless self.new_record?
          log_enrichment(attribute_name: attr, attribute_value: value, source: source, metadata: metadata)
        end
      end

      save

      # For virtual attributes (like tag_ids), previous_changes won't track them
      # So we need to check if the value actually changed by comparing before/after
      if previous_changes.any?
        was_modified = true
      else
        # Check if any virtual attributes changed by comparing current value with what we set
        enrichable_attrs.each do |attr, new_value|
          # Get the current value after save (for virtual attributes, this reflects the change)
          current_value = if respond_to?(attr.to_sym)
            send(attr.to_sym)
          else
            self[attr.to_s]
          end

          old_value = current_values[attr]
          if old_value.is_a?(Array) && new_value.is_a?(Array) && current_value.is_a?(Array)
            was_modified = true if old_value.sort != current_value.sort
          elsif old_value != current_value
            was_modified = true
          end
          break if was_modified
        end
      end
    end

    # Return whether any attributes were actually saved
    was_modified
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

  def clear_ai_cache
    ActiveRecord::Base.transaction do
      ai_enrichments = data_enrichments.where(source: "ai")

      # Only unlock attributes where current value still matches what AI set
      # If user changed the value, they took ownership - don't unlock
      attrs_to_unlock = ai_enrichments.select do |enrichment|
        attr_name = enrichment.attribute_name
        current_value = respond_to?(attr_name) ? send(attr_name) : self[attr_name]
        current_value.to_s == enrichment.value.to_s
      end.map(&:attribute_name).uniq

      # Batch unlock in a single update
      if attrs_to_unlock.any?
        new_locked_attrs = locked_attributes.except(*attrs_to_unlock)
        update_column(:locked_attributes, new_locked_attrs) if new_locked_attrs != locked_attributes
      end

      # Delete AI enrichment records
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
