# frozen_string_literal: true

# Signed tokens that split a write into preview and confirmation. A preview
# issues a token bound to the tool that accepts it (its purpose), the user, the
# target record and the state the preview showed; the write runs only with a
# token that still matches. So the preview can't be skipped, and a token can't
# be replayed on another record, by another user, after the target changed, or
# after PREVIEW_TOKEN_TTL.
#
# Used by apply_rule (see RuleSupport) and by the delete tools, which preview
# when called without a token (preview_before_delete).
module Assistant::Function::PreviewToken
  PREVIEW_TOKEN_TTL = 30.minutes

  private
    def issue_preview_token(target, state)
      preview_token_verifier.generate(
        { "target_id" => target.id, "user_id" => user.id, "state" => state },
        purpose: preview_token_purpose, expires_in: PREVIEW_TOKEN_TTL
      )
    end

    # The token's payload, or nil when it is missing, forged, expired, or
    # issued to another user, target or tool.
    def read_preview_token(token, target)
      payload = preview_token_verifier.verified(token.to_s, purpose: preview_token_purpose) if token.present?
      return nil unless payload.is_a?(Hash)
      return nil unless payload["target_id"] == target.id && payload["user_id"] == user.id

      payload
    end

    # Without a preview_token, returns the preview and a token and deletes
    # nothing. With a token issued for this target and this exact preview, it
    # yields, and the block performs the delete.
    def preview_before_delete(params, target, preview)
      state = Digest::SHA256.hexdigest(preview.to_json)

      if params["preview_token"].blank?
        return {
          success: true,
          deleted: false,
          preview: preview,
          preview_token: issue_preview_token(target, state),
          message: "Nothing was deleted. Show the user what would be removed; only if they confirm, call #{name} again with this preview_token (it expires after #{PREVIEW_TOKEN_TTL.inspect})."
        }
      end

      token = read_preview_token(params["preview_token"], target)
      unless token
        return {
          success: false,
          error: "preview_required",
          message: "That preview_token is not valid here: it expired or was issued for another record. Nothing was deleted; call #{name} without preview_token to preview again."
        }
      end

      unless token["state"] == state
        return {
          success: false,
          error: "preview_stale",
          preview: preview,
          preview_token: issue_preview_token(target, state),
          message: "What would be deleted changed since that preview. Nothing was deleted; show the user this preview and, if they confirm, retry with its preview_token."
        }
      end

      yield
    end

    def preview_token_purpose
      name
    end

    def preview_token_verifier
      Rails.application.message_verifier("assistant/preview")
    end
end
