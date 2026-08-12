class Assistant::Function::CreateTag < Assistant::Function
  class << self
    def name
      "create_tag"
    end

    def description
      <<~INSTRUCTIONS
        Creates a new tag for the user's family.

        Tags are applied to transactions to organize them beyond categories.
        If color is omitted, one is chosen automatically from the default palette.
        Tag names must be unique within the family.
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
          description: "Tag name (must be unique within the family)"
        },
        color: {
          type: "string",
          description: "Hex color code (e.g. #e99537). If omitted, one is chosen from the default palette."
        }
      }
    )
  end

  def call(params = {})
    name = params["name"].to_s.strip
    return error("name_required", "Please provide a name for the tag.") if name.blank?

    color = params["color"].presence || Tag::COLORS.sample
    tag = family.tags.new(name: name, color: color)

    if tag.save
      { success: true, tag: { id: tag.id, name: tag.name, color: tag.color }, message: "Tag '#{tag.name}' created." }
    else
      error("validation_failed", tag.errors.full_messages.join("; "))
    end
  end

  private
    def error(key, message)
      { success: false, error: key, message: message }
    end
end
