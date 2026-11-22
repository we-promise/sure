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
end
