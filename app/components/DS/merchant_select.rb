class DS::MerchantSelect < DesignSystemComponent
  attr_reader :form, :method, :merchants, :selected_id, :disabled, :auto_submit,
              :menu_placement, :label, :include_blank, :variant, :fallback_text, :size, :entry_id

  MENU_PLACEMENTS = %w[auto down up].freeze

  def initialize(form:, method:, merchants:, selected_id:, disabled: false, auto_submit: false,
                 menu_placement: :auto, label: nil, include_blank: nil, variant: :default,
                 fallback_text: nil, size: :md, selected_merchant: nil, options_url: nil, entry_id: nil)
    @form = form
    @method = method
    @merchants = merchants
    @selected_id = selected_id&.to_s
    @disabled = disabled
    @auto_submit = auto_submit
    @menu_placement = normalize_menu_placement(menu_placement)
    @label = label
    @include_blank = include_blank
    @variant = variant.to_sym
    @fallback_text = fallback_text
    @size = size.to_sym
    @selected_merchant_record = selected_merchant
    @options_url = options_url
    @entry_id = entry_id
  end

  def field_name
    "#{form.object_name}[#{method}]"
  end

  def menu_id
    @menu_id ||= "merchant_select_#{field_name.gsub(/\W+/, "_")}_#{object_id}"
  end

  def selected_merchant
    @selected_merchant_record || merchants.find { |merchant| merchant.id.to_s == selected_id }
  end

  def options_url
    @options_url
  end

  def selected_merchant_logo_url
    merchant = selected_merchant
    return nil unless merchant&.display_logo_url.present?

    Setting.transform_brand_fetch_url(merchant.display_logo_url)
  end

  def avatar_variant?
    variant == :avatar
  end

  def avatar_size_classes
    { sm: "w-5 h-5", md: "w-8 h-8", lg: "w-9 h-9" }.fetch(size)
  end

  def avatar_title
    return include_blank || I18n.t("transactions.form.merchant_label") unless selected_merchant

    [ selected_merchant.name, selected_merchant.website_url.presence ].compact.join(" · ")
  end

  private

    def normalize_menu_placement(value)
      normalized = value.to_s.downcase
      MENU_PLACEMENTS.include?(normalized) ? normalized : "auto"
    end
end
