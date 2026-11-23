# frozen_string_literal: true

class DS::LocationPicker < DesignSystemComponent
  attr_reader :form, :entry, :can_annotate

  def initialize(form:, entry:, can_annotate: true)
    @form = form
    @entry = entry
    @can_annotate = can_annotate
  end

  def located?
    entry.located?
  end

  def display_value
    entry.location_name
  end

  # Scoped to the entry so a page showing more than one picker still pairs each
  # label with its own input.
  def search_input_id
    "location_picker_search_#{entry.id}"
  end

  def search_label_id
    "#{search_input_id}_label"
  end
end
