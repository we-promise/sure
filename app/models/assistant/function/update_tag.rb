class Assistant::Function::UpdateTag < Assistant::Function
  class << self
    def name = "update_tag"
    def description = "Updates an existing family tag by its stable ID from get_tags."
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Tag ID from get_tags" },
        new_name: { type: "string", description: "New tag name" },
        color: { type: "string", description: "New hex color code" }
      }
    )
  end

  def call(params = {})
    tag = valid_uuid?(params["id"]) ? family.tags.find_by(id: params["id"]) : nil
    return error("not_found", "Tag not found.") unless tag

    attrs = {}
    attrs[:name] = params["new_name"].strip if params["new_name"].present?
    attrs[:color] = params["color"].strip if params["color"].present?
    return error("no_changes", "Provide at least one of new_name or color to update.") if attrs.empty?

    if tag.update(attrs)
      { success: true, tag: { id: tag.id, name: tag.name, color: tag.color }, message: "Tag updated." }
    else
      error("validation_failed", tag.errors.full_messages.join("; "))
    end
  end

  private
    def error(key, message)
      { success: false, error: key, message: }
    end
end
