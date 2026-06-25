class Assistant::Function::GetTags < Assistant::Function
  class << self
    def name
      "get_tags"
    end

    def description
      <<~INSTRUCTIONS
        Returns all tags defined for the user's family, sorted alphabetically.

        Use this when the user wants to see available tags or before referencing
        a tag in another operation like create_tag or update_tag.
      INSTRUCTIONS
    end
  end

  def call(params = {})
    tags = family.tags.alphabetically

    {
      tags: tags.map { |t| { id: t.id, name: t.name, color: t.color } },
      total: tags.size
    }
  end
end
