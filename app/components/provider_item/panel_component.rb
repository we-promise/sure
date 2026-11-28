# frozen_string_literal: true

# A provider's panel under Settings > Providers: its setup steps, an error
# alert, each connection with its sync, disconnect and edit form, and a form to
# add a connection. The provider fills the `setup_steps` slot and supplies its
# credential fields as `<key>_items/_credential_fields` (locals `form:`,
# `item:`, `editing:`), rendered inside each form. Messages come from the
# provider's own `<key>_items.provider_panel.*` keys.
class ProviderItem::PanelComponent < ApplicationComponent
  renders_one :setup_steps

  attr_reader :items, :new_item, :error_message

  def initialize(items:, new_item:, error_message: nil)
    @items = items
    @new_item = new_item
    @error_message = error_message
  end

  def provider_key
    new_item.provider_key
  end

  def panel_dom_id
    panel = Provider::Factory.panel_declarations.find { |declaration| declaration[:key] == provider_key }
    "#{panel.fetch(:turbo_id)}-providers-panel"
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
    t("#{provider_key}_items.provider_panel.#{key}", **options)
  end
end
