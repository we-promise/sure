# frozen_string_literal: true

# Signed tokens that split a write into preview and confirmation. A preview
# issues a token bound to the tool that accepts it (its purpose), the user, the
# target record and the state the preview showed; the write runs only with a
# token that still matches. So the preview can't be skipped, and a token can't
# be replayed on another record, by another user, after the target changed, or
# after PREVIEW_TOKEN_TTL.
#
# Used by apply_rule (see RuleSupport) and by the tools that delete or undo
# data (delete_transaction, delete_category, unmatch_transfer), which preview
# when called without a token (confirm_with_preview).
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

    # Without a preview_token, returns the preview and a token and changes
    # nothing (done_key, the result's success flag, is false). With a token
    # issued for this target and this exact preview, it locks +lock+ (the rows
    # whose writers would change the preview, in their lock order), rebuilds the
    # preview and yields it inside that transaction, so the block acts on the
    # state the user was shown. +preview+ builds it from the current records.
    def confirm_with_preview(params, target, preview, lock: [ target ], done_key: :deleted)
      if params["preview_token"].blank?
        current = preview.call
        return {
          success: true,
          done_key => false,
          preview: current,
          preview_token: issue_preview_token(target, preview_digest(current)),
          message: "Nothing was changed. Show the user this preview; only if they confirm, call #{name} again with this preview_token (it expires after #{PREVIEW_TOKEN_TTL.inspect})."
        }
      end

      token = read_preview_token(params["preview_token"], target)
      unless token
        return {
          success: false,
          error: "preview_required",
          message: "That preview_token is not valid here: it expired or was issued for something else. Nothing was changed; call #{name} without preview_token to preview again."
        }
      end

      # Uncached: the request's query cache may hold reads from before the lock.
      ApplicationRecord.uncached do
        ApplicationRecord.transaction do
          lock.each(&:lock!)
          current = preview.call

          next stale_preview(target, current) unless token["state"] == preview_digest(current)

          yield current
        end
      end
    rescue ActiveRecord::RecordNotFound
      { success: false, error: "not_found", message: "It no longer exists. Nothing was changed." }
    end

    def stale_preview(target, preview)
      {
        success: false,
        error: "preview_stale",
        preview: preview,
        preview_token: issue_preview_token(target, preview_digest(preview)),
        message: "What the call would change is different since that preview. Nothing was changed; show the user this preview and, if they confirm, retry with its preview_token."
      }
    end

    def preview_digest(preview)
      Digest::SHA256.hexdigest(preview.to_json)
    end

    def preview_token_purpose
      name
    end

    def preview_token_verifier
      Rails.application.message_verifier("assistant/preview")
    end
end
