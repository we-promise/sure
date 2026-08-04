class Assistant::Function::DeleteTag < Assistant::Function
  class << self
    def name = "delete_tag"
    def description = "Permanently deletes a family tag, optionally reassigning taggings to another tag."
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Tag ID from get_tags" },
        replacement_tag_id: { type: [ "string", "null" ], description: "Optional replacement tag ID" }
      }
    )
  end

  def call(params = {})
    tag_id = normalized_uuid(params["id"])
    return error("not_found", "Tag not found.") unless tag_id

    replacement_id = params["replacement_tag_id"].presence
    return error("invalid_replacement", "Replacement tag not found.") if replacement_id && !valid_uuid?(replacement_id)

    replacement_id = replacement_id.to_s if replacement_id
    return error("invalid_replacement", "Replacement tag must differ from the deleted tag.") if replacement_id == tag_id

    Tag.transaction do
      tags = family.tags
        .where(id: [ tag_id, replacement_id ].compact)
        .order(:id)
        .lock
        .index_by { |tag| tag.id.to_s }
      tag = tags[tag_id]
      return error("not_found", "Tag not found.") unless tag
      replacement = replacement_id && tags[replacement_id]
      return error("invalid_replacement", "Replacement tag not found.") if replacement_id && !replacement

      name = tag.name
      tag.replace_and_destroy!(replacement)
      {
        success: true,
        deleted_tag_id: tag_id,
        replacement_tag_id: replacement&.id,
        message: "Tag '#{name}' deleted."
      }
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
    message = e.record.respond_to?(:errors) ? e.record.errors.full_messages.join("; ") : e.message
    error("delete_failed", message)
  end

  private
    def normalized_uuid(value)
      valid_uuid?(value) ? value.to_s : nil
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
