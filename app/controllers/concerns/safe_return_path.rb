# The `return_to` param as a path on this site, or nil. Rejects absolute and
# protocol-relative URLs (`//host`, `/\host`, and their percent-encoded forms)
# so a crafted link can't send the user off the site after a provider flow.
module SafeReturnPath
  extend ActiveSupport::Concern

  private
    def safe_return_to_path
      return nil if params[:return_to].blank?

      return_to = params[:return_to].to_s.strip
      return nil unless return_to.start_with?("/")

      second_character = return_to[1]
      return nil if second_character.blank?
      return nil if second_character == "/" || second_character == "\\"
      return nil if second_character.match?(/[[:space:][:cntrl:]]/)
      return nil if encoded_path_separator?(return_to)

      uri = URI.parse(return_to)

      return nil if uri.scheme.present? || uri.host.present?

      return_to
    rescue URI::InvalidURIError
      nil
    end

    def encoded_path_separator?(return_to)
      encoded_second_character = return_to[1, 3]
      return false unless encoded_second_character&.start_with?("%")

      decoded = URI.decode_www_form_component(encoded_second_character)
      decoded == "/" || decoded == "\\"
    rescue ArgumentError
      false
    end
end
