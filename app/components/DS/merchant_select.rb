class DS::MerchantSelect < DesignSystemComponent
  attr_reader :form, :method, :merchants, :selected_id, :disabled, :auto_submit,
              :menu_placement, :label, :include_blank

  MENU_PLACEMENTS = %w[auto down up].freeze

  def initialize(form:, method:, merchants:, selected_id:, disabled: false, auto_submit: false,
                 menu_placement: :auto, label: nil, include_blank: nil)
    @form = form
    @method = method
    @merchants = merchants
    @selected_id = selected_id&.to_s
    @disabled = disabled
    @auto_submit = auto_submit
    @menu_placement = normalize_menu_placement(menu_placement)
    @label = label
    @include_blank = include_blank
  end

  def field_name
    "#{form.object_name}[#{method}]"
  end

  def menu_id
    @menu_id ||= "merchant_select_#{field_name.gsub(/\W+/, "_")}_#{object_id}"
  end

  def selected_merchant
    merchants.find { |merchant| merchant.id.to_s == selected_id }
  end

  def selected_merchant_logo_url
    merchant = selected_merchant
    return nil unless merchant&.respond_to?(:logo_url) && merchant.logo_url.present?

    Setting.transform_brand_fetch_url(merchant.logo_url)
  end

  private

    def normalize_menu_placement(value)
      normalized = value.to_s.downcase
      MENU_PLACEMENTS.include?(normalized) ? normalized : "auto"
    end
end
