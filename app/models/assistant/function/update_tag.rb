class Assistant::Function::UpdateTag < Assistant::Function
  class << self
    def name
      "update_tag"
    end

    def description
      <<~INSTRUCTIONS
        Updates an existing tag's name or color.

        Identify the tag by its current name. At least one of new_name or color must be provided.
        Use get_tags first to confirm the tag exists.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "name" ],
      properties: {
        name: {
          type: "string",
          description: "Current name of the tag to update",
          enum: family_tag_names
        },
        new_name: {
          type: "string",
          description: "New name for the tag (optional)"
        },
        color: {
          type: "string",
          description: "New hex color code (optional)"
        }
      }
    )
  end

  def call(params = {})
    tag = family.tags.find_by(name: params["name"].to_s.strip)
    return error("not_found", "Tag '#{params["name"]}' not found.") unless tag

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
      { success: false, error: key, message: message }
    end
end
