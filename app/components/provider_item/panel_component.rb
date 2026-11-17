# frozen_string_literal: true

# A provider's panel under Settings > Providers: its setup steps, an error
# alert, each connection with its sync, disconnect and edit form, and a form to
# add a connection. A panel declared `shape: :single` instead shows one form for
# `item:` (the provider passes an existing connection or a new one), which
# creates or updates it. The provider fills the `setup_steps` slot and supplies
# its credential fields as `<key>_items/_credential_fields` (locals `form:`,
# `item:`, `editing:`), rendered inside each form. Messages come from the
# provider's own keys under `i18n_scope`, by default `<key>_items.provider_panel`.
# `variant: :classic` reproduces Mercury's panel, whose disconnect buttons carry
# no aria-label.
class ProviderItem::PanelComponent < ApplicationComponent
  renders_one :setup_steps

  attr_reader :items, :new_item, :item, :error_message

  def initialize(items: [], new_item: nil, item: nil, error_message: nil, i18n_scope: nil, variant: :kit)
    @items = items
    @new_item = new_item
    @item = item
    @error_message = error_message
    @i18n_scope = i18n_scope
    @variant = variant
  end

  def disconnect_aria(item)
    { label: panel_t("disconnect_label", name: item.name) } unless @variant == :classic
  end

  def provider_key
    (item || new_item).provider_key
  end

  def panel_declaration
    Settings::ProvidersController::FAMILY_PANELS_BY_KEY.fetch(provider_key)
  end

  def panel_dom_id
    "#{panel_declaration[:turbo_id]}-providers-panel"
  end

  def single_connection?
    panel_declaration[:shape] == :single
  end

  # The bottom form: a new connection for a list, else the single connection.
  def form_item
    single_connection? ? item : new_item
  end

  def form_url
    form_item.new_record? ? items_path : item_path(form_item)
  end

  def form_method
    form_item.new_record? ? :post : :patch
  end

  def form_submit_label
    return panel_t("add_connection") unless single_connection?

    panel_t(form_item.new_record? ? "save_and_connect" : "update_connection")
  end

  def form_scope
    :"#{provider_key}_item"
  end

  def items_path
    helpers.public_send(:"#{provider_key}_items_path")
  end

  def item_path(item)
    helpers.polymorphic_path(item)
  end

  def sync_path(item)
    helpers.public_send(:"sync_#{provider_key}_item_path", item, source: "panel")
  end

  def setup_accounts_path(item)
    helpers.public_send(:"setup_accounts_#{provider_key}_item_path", item)
  end

  def credential_fields(form, item, editing:)
    helpers.render("#{provider_key}_items/credential_fields", form: form, item: item, editing: editing)
  end

  def panel_t(key, **options)
    t("#{@i18n_scope || "#{provider_key}_items.provider_panel"}.#{key}", **options)
  end
end
