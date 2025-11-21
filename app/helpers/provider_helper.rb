# Helper for rendering per-family provider configuration panels
module ProviderHelper
  # Renders a per-family provider configuration panel
  # @param provider_key [String, Symbol] The provider key (e.g., :lunchflow)
  # @param error_message [String] Optional error message to display
  # @return [String] HTML for the provider panel
  def render_per_family_provider_panel(provider_key, error_message: nil)
    config = Provider::PerFamilyConfigurationRegistry.get(provider_key.to_s)
    return "" unless config

    adapter_class = Provider::PerFamilyConfigurationRegistry.get_adapter_class(provider_key.to_s)
    return "" unless adapter_class

    items_association = adapter_class.items_association_name
    item = Current.family.send(items_association).first_or_initialize(name: "#{provider_key.to_s.titleize} Connection")
    is_new_record = item.new_record?

    render partial: "provider/per_family_panel",
           locals: {
             config: config,
             item: item,
             is_new_record: is_new_record,
             error_message: error_message,
             provider_key: provider_key.to_s,
             items_association: items_association
           }
  end

  # Renders the form fields for a per-family provider
  # @param form [ActionView::Helpers::FormBuilder] The form builder
  # @param config [Provider::PerFamilyConfigurable::PerFamilyConfiguration] The configuration
  # @param item [ActiveRecord::Base] The item instance
  # @param is_new_record [Boolean] Whether this is a new record
  # @return [String] HTML for the form fields
  def render_per_family_provider_fields(form, config, item, is_new_record)
    safe_join(
      config.fields.map do |field|
        placeholder = if field.placeholder.present?
          field.placeholder
        elsif is_new_record
          field.default ? "#{field.default} (default)" : "Enter #{field.label.downcase}"
        else
          field.default ? "#{field.default} (default)" : "Enter new #{field.label.downcase} to update"
        end

        form.text_field field.name,
                        label: field.label,
                        placeholder: placeholder,
                        type: field.input_type,
                        value: field.secret && !is_new_record ? nil : item.public_send(field.name)
      end
    )
  end

  # Returns the path for creating or updating a per-family provider item
  # @param item [ActiveRecord::Base] The item instance
  # @param provider_key [String] The provider key
  # @return [String] The path for the form
  def per_family_provider_item_path(item, provider_key)
    if item.new_record?
      public_send("#{provider_key}_items_path")
    else
      public_send("#{provider_key}_item_path", item)
    end
  end

  # Returns the HTTP method for creating or updating a per-family provider item
  # @param item [ActiveRecord::Base] The item instance
  # @return [Symbol] :post for new records, :patch for existing
  def per_family_provider_item_method(item)
    item.new_record? ? :post : :patch
  end
end
