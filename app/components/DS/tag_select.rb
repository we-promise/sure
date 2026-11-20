class DS::TagSelect < DesignSystemComponent
  attr_reader :form, :tags, :selected_ids, :attribute, :label, :show_label, :disabled,
              :auto_submit, :update_url, :menu_placement, :offset, :compact

  MENU_PLACEMENTS = %w[auto down up].freeze

  def initialize(form:, tags:, selected_ids:, attribute: :tag_ids, label: nil, show_label: true,
                 disabled: false, auto_submit: false, update_url: nil, menu_placement: :auto, offset: 6, compact: false)
    @form = form
    @tags = tags
    @selected_ids = selected_ids.map(&:to_s)
    @attribute = attribute
    @label = label
    @show_label = show_label
    @disabled = disabled
    @auto_submit = auto_submit
    @update_url = update_url
    @menu_placement = normalize_menu_placement(menu_placement)
    @offset = offset
    @compact = compact
  end

  def field_name
    "#{form.object_name}[#{attribute}][]"
  end

  # Compact keeps the trigger at a plain input's height, so it lines up with the selects next to
  # it in dense rows (split rows); selected pills overlap the padding instead of growing the field.
  def trigger_height_class
    compact ? "min-h-5" : "min-h-7"
  end

  def selection_class
    compact ? "-my-0.5" : nil
  end

  def menu_id
    @menu_id ||= "tag_select_#{field_name.gsub(/\W+/, "_")}_#{object_id}"
  end

  private

    def normalize_menu_placement(value)
      normalized = value.to_s.downcase
      MENU_PLACEMENTS.include?(normalized) ? normalized : "auto"
    end
end
