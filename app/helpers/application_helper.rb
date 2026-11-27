module ApplicationHelper
  MONEY_FIELD_MAX_EXPONENT = 20

  include Pagy::Frontend

  # Whether an AI feature (a key in Ai::Routes::MATRIX) can run for the current family and user,
  # so a view shows its AI affordance only then.
  def ai_feature_available?(feature)
    Ai.available?(feature, family: Current.family, user: Current.user)
  end

  def product_name
    Rails.configuration.x.product_name
  end

  def brand_name
    Rails.configuration.x.brand_name
  end

  # The instance's own privacy policy or terms URL, or nil when unset. The
  # /privacy and /terms routes redirect to the same variables.
  def legal_page_url(page)
    ENV[{ privacy: "LEGAL_PRIVACY_URL", terms: "LEGAL_TERMS_URL" }.fetch(page)].presence
  end

  def styled_form_with(**options, &block)
    options[:builder] = StyledFormBuilder
    form_with(**options, &block)
  end

  # Masks a sensitive identifier (IBAN, account number, ...) down to its last
  # 4 characters for display, e.g. "•••1234". Returns nil for blank input.
  def mask_last4(value)
    return nil if value.blank?

    "•••#{value.to_s.last(4)}"
  end

  # Locale-aware ordinal label for integers.
  # English falls through to Ruby's ordinalize ("1st"); Catalan returns "1r"/"2n"/...
  def localized_ordinal(number)
    case I18n.locale
    when :ca
      n = number.to_i
      suffix = case n
      when 1, 3 then "r"
      when 2 then "n"
      when 4 then "t"
      else "è"
      end
      "#{n}#{suffix}"
    else
      number.to_i.ordinalize
    end
  end

  def icon(key, size: "md", color: "default", custom: false, as_button: false, **opts)
    extra_classes = opts.delete(:class)
    sizes = { xs: "w-3 h-3", sm: "w-4 h-4", md: "w-5 h-5", lg: "w-6 h-6", xl: "w-7 h-7", "2xl": "w-8 h-8" }
    colors = { default: "text-secondary", white: "text-inverse", success: "text-success", warning: "text-warning", destructive: "text-destructive", info: "text-info", current: "text-current" }

    icon_classes = class_names(
      "shrink-0",
      sizes[size.to_sym],
      colors[color.to_sym],
      extra_classes
    )

    resolved_key = normalize_icon_key(key)

    if custom
      inline_svg_tag("#{resolved_key}.svg", class: icon_classes, **opts)
    elsif as_button
      render DS::Button.new(variant: "icon", class: extra_classes, icon: resolved_key, size: size, type: "button", **opts)
    else
      safe_lucide_icon(resolved_key, class: icon_classes, **opts)
    end
  end

  # The chevron for a DS::Disclosure summary_content slot; it turns as the disclosure opens.
  def disclosure_chevron
    icon "chevron-right", size: "sm", class: "[details[open]>summary_&]:rotate-90 motion-safe:transition-transform motion-safe:duration-150"
  end

  # Convert alpha (0-1) to 8-digit hex (00-FF)
  def hex_with_alpha(hex, alpha)
    alpha_hex = (alpha * 255).round.to_s(16).rjust(2, "0")
    "#{hex}#{alpha_hex}"
  end

  def title(page_title)
    content_for(:title) { page_title }
  end

  def header_title(page_title)
    content_for(:header_title) { page_title }
  end

  def header_description(page_description)
    content_for(:header_description) { page_description }
  end

  def page_active?(path)
    current_page?(path) || (request.path.start_with?(path) && path != "/")
  end

  # Wraps a nav-item hash so a single call performs both halves of a
  # preview-gated entry: returns `nil` for users without the flag (so the
  # entry never reaches the rendered nav), and stamps `preview: true` on
  # the hash for users with the flag (so the partial paints the violet
  # dot on the icon). Use inside an `Array#compact` nav-items list.
  def preview_gated_nav_item(item)
    return nil unless preview_features_enabled?
    item.merge(preview: true)
  end

  # Bills is only meaningful while recurring detection is on, since a family that has
  # turned it off has nothing to list. Returns nil so the entry drops out of the
  # `Array#compact` nav list entirely rather than leading to an empty page. The
  # subsystem also ships as a preview feature, so the entry is preview-gated on
  # top: hidden without the flag, violet-dotted with it.
  def bills_nav_item
    return nil if Current.family.nil? || Current.family.recurring_transactions_disabled?

    preview_gated_nav_item(
      {
        name: t("layouts.application.nav.bills"),
        path: bills_path,
        icon: "receipt",
        icon_custom: false,
        active: page_active?(bills_path)
      }
    )
  end

  # Budgets and Goals share one nav slot. Preview users get the "Plan" hub
  # entry fronting both (it stays lit while browsing either subpage, since
  # page_active? is a path-prefix match and /budgets · /goals don't share
  # the /plan prefix). Everyone else gets exactly the pre-Plan Budgets
  # entry — Goals was already hidden without the flag, so their nav is
  # unchanged.
  def plan_nav_item
    if preview_features_enabled?
      {
        name: t("layouts.application.nav.plan"),
        path: plan_path,
        icon: "compass",
        icon_custom: false,
        active: page_active?(plan_path) || page_active?(budgets_path) || page_active?(goals_path),
        preview: true
      }
    else
      {
        name: t("layouts.application.nav.budgets"),
        path: budgets_path,
        icon: "map",
        icon_custom: false,
        active: page_active?(budgets_path)
      }
    end
  end

  # The family-wide investment hub. Preview-gated (hidden entirely without the
  # flag) and desktop-only: the bottom bar already carries five entries at the
  # width it has, and the hub is a wide, multi-section page. `desktop_only`
  # is filtered out of the mobile bar in the layout, the mirror of the
  # `mobile_only` flag the Assistant entry uses.
  def portfolio_nav_item
    preview_gated_nav_item(
      {
        name: t("layouts.application.nav.portfolio"),
        path: portfolio_path,
        icon: "briefcase",
        icon_custom: false,
        active: page_active?(portfolio_path),
        desktop_only: true
      }
    )
  end

  # Wrapper around I18n.l to support custom date formats
  def format_date(object, format = :default, options = {})
    date = object.to_date

    format_code = options[:format_code] || Current.family&.date_format

    if format_code.present?
      date.strftime(format_code)
    else
      I18n.l(date, format: format, **options)
    end
  end


  def family_moniker
    Current.family&.moniker_label || I18n.t("shared.family_moniker.singular")
  end

  def family_moniker_downcase
    family_moniker.downcase
  end

  def family_moniker_plural
    Current.family&.moniker_label_plural || I18n.t("shared.family_moniker.plural")
  end

  def family_moniker_plural_downcase
    family_moniker_plural.downcase
  end

  def format_money(number_or_money, options = {})
    return nil unless number_or_money

    Money.new(number_or_money).format(options)
  end

  # Format each native-currency total independently, preserving order and transfer exclusions.
  def totals_by_currency(collection:, money_method:, separator: " | ", negate: false)
    collection.group_by(&:currency)
              .transform_values { |item| calculate_total(item, money_method, negate) }
              .map { |_currency, money| format_money(money) }
              .join(separator)
  end

  # A saved or typed amount kept as text (a rule's split share or amount
  # condition, a search filter) as a number for a money field, or nil when it
  # is blank or not a number, and the decimals to show it with: at least the
  # currency's, more when the value has them, so saving unchanged keeps it.
  def money_field_value(raw, currency: Current.family.currency, min_precision: nil)
    min_precision = [ Money::Currency.new(currency).default_precision, min_precision.to_i ].max
    amount = BigDecimal(raw.to_s)
    # An exponent far outside any amount ("1e-1000000000") is not one, and
    # writing it out in plain notation would take a string of that length.
    return [ nil, min_precision ] unless amount.finite? && amount.exponent.abs <= MONEY_FIELD_MAX_EXPONENT

    [ amount, [ amount_decimals(amount), min_precision ].max ]
  rescue ArgumentError, TypeError
    [ nil, min_precision ]
  end

  # A number as plain decimal text ("0.000063", not Float#to_s's "6.3e-05"),
  # for a money field that shows a value as given (an exchange rate). Text
  # that is not a number is returned unchanged, so an invalid entry is shown
  # as typed.
  def plain_decimal_text(value)
    return value.to_s unless value.is_a?(Numeric)
    return "" unless value.to_f.finite?

    BigDecimal(value.to_s).to_s("F").delete_suffix(".0")
  end

  # The decimals a saved amount has (70.1234 has 4, 1500 has 0), counted from
  # its significant digits and exponent and capped, so a stray "1e-15" cannot
  # ask a field for 15 decimals. 0 for anything that is not a finite number.
  def amount_decimals(value)
    amount = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
    return 0 unless amount.finite? && amount.exponent.abs <= MONEY_FIELD_MAX_EXPONENT

    _sign, digits, _base, exponent = amount.split
    (digits.sub(/0+\z/, "").length - exponent).clamp(0, 10)
  rescue ArgumentError, TypeError
    0
  end

  # The decimals a money field needs to show a saved amount unchanged, or nil
  # when the currency's own are enough, so the field keeps following the
  # currency picker for ordinary amounts.
  def saved_amount_precision(value, currency:)
    _amount, precision = money_field_value(value, currency: currency)
    precision if precision > Money::Currency.new(currency).default_precision
  end

  def currency_picker_options_for_family(family = Current.family, extra: [])
    return Money::Currency.as_options.map(&:iso_code) unless family

    family.enabled_currency_codes(extra:)
  end

  def currency_label(currency_or_code)
    currency = currency_or_code.is_a?(Money::Currency) ? currency_or_code : Money::Currency.new(currency_or_code)
    "#{currency.name} (#{currency.iso_code})"
  end

  def show_super_admin_bar?
    if params[:admin].present?
      cookies.permanent[:admin] = params[:admin]
    end

    cookies[:admin] == "true"
  end

  def sidekiq_web_available?
    named_routes = Rails.application.routes.named_routes
    named_routes.route_defined?(:sidekiq_web_path) || named_routes.route_defined?(:sidekiq_web_url)
  end

  def assistant_icon
    type = Current.family&.effective_assistant_type || "builtin"
    type == "external" ? "claw" : "ai"
  end

  def default_ai_model
    # Always return a valid model, never nil or empty
    # Delegates to Chat.default_model for consistency
    Chat.default_model
  end

  # Renders Markdown text using Redcarpet
  def markdown(text)
    return "" if text.blank?

    # filter_html drops raw HTML present in the input. It is not redundant with
    # the sanitize below: `div`, `span`, `class` and `style` have to stay on
    # that allow-list for footnotes, code blocks and table alignment, so
    # without this a chat message could ship `<div class="fixed inset-0">` and
    # cover the app.
    renderer = Redcarpet::Render::HTML.new(
      hard_wrap: true,
      filter_html: true,
      link_attributes: { target: "_blank", rel: "noopener noreferrer" }
    )

    markdown = Redcarpet::Markdown.new(
      renderer,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      superscript: true,
      underline: true,
      highlight: true,
      quote: true,
      footnotes: true
    )

    # The second layer, for the markup the renderer itself produces: a markdown
    # link carries whatever scheme the author wrote, so `[x](javascript:...)`
    # survives filter_html and only the allow-list drops it (CWE-79). Every tag
    # the extensions above generate has to be on it: `u` (underline), `q`
    # (quote), `mark`, `del`, `sup`, and `style` for table column alignment.
    sanitize(
      markdown.render(text),
      tags: %w[p br strong em u q a img ul ol li h1 h2 h3 h4 h5 h6 pre code blockquote table thead tbody tr th td span div sup sub del mark ins hr dl dt dd],
      attributes: %w[href target rel class id src alt title style]
    )
  end

  # Generate the callback URL for Enable Banking OAuth (used in views and controller).
  # In production, uses the standard Rails route.
  # In development, uses DEV_WEBHOOKS_URL if set (e.g., ngrok URL).
  def enable_banking_callback_url
    return callback_enable_banking_items_url if Rails.env.production?

    ENV.fetch("DEV_WEBHOOKS_URL", root_url).chomp("/") + "/enable_banking_items/callback"
  end

  # The redirect URI registered on the TrueLayer app. TRUELAYER_REDIRECT_URI
  # overrides it for instances behind a proxy that doesn't forward the
  # public host; it must exactly match one registered on the TrueLayer app.
  def truelayer_callback_url
    ENV["TRUELAYER_REDIRECT_URI"].presence || callback_truelayer_items_url
  end

  # Formats a holding quantity with adaptive precision based on the value size.
  # Shows more decimal places for small quantities (common with crypto).
  #
  # @param qty [Numeric] The quantity to format
  # @param exact [Boolean] Show the full stored precision, without rounding
  # @return [String] Formatted quantity with appropriate precision
  def format_quantity(qty, exact: false)
    return "0" if qty.nil? || qty.zero?

    abs_qty = qty.abs

    precision = if exact
      18    # Preserve the full stored precision for crypto quantities
    elsif abs_qty >= 1
      1     # "10.4"
    elsif abs_qty >= 0.01
      2     # "0.52"
    elsif abs_qty >= 0.0001
      4     # "0.0005"
    else
      8     # "0.00000052"
    end

    # Use strip_insignificant_zeros to avoid trailing zeros like "0.50000000"
    number_with_precision(qty, precision: precision, strip_insignificant_zeros: true)
  end

  private
    def safe_lucide_icon(key, **opts)
      lucide_icon(key, **opts)
    rescue StandardError => e
      Rails.logger.warn("[ApplicationHelper] Falling back to key for unknown icon #{key.inspect}: #{e.message}")
      lucide_icon("key", **opts)
    end

    def normalize_icon_key(key)
      normalized = key.to_s.strip
      return normalized if normalized.blank?

      normalized.downcase
    end

    # Exclude transfers while preserving the original group currency even when its total is zero.
    def calculate_total(item, money_method, negate)
      # Filter out transfer-type transactions from entries
      # Only Entry objects have entryable transactions, Account objects don't
      items = item.reject do |i|
        i.is_a?(Entry) &&
        i.entryable.is_a?(Transaction) &&
        i.entryable.transfer?
      end
      # Keep the group's currency when every entry is excluded from the total.
      total = items.sum(Money.new(0, item.first.currency), &money_method)
      negate ? -total : total
    end
end
