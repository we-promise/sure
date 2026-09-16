# frozen_string_literal: true

class Assistant::Function::UploadAccountStatement < Assistant::Function
  include Assistant::Function::StatementVaultSupport

  class << self
    def name
      "upload_account_statement"
    end

    def description
      <<~INSTRUCTIONS
        Store a statement document (PDF, CSV or XLSX) in the family's Statement Vault,
        the canonical archive of primary-source financial documents.

        The vault keeps the original bytes and indexes them by SHA-256, so uploading
        the same file twice is safe: the existing statement is returned with
        `duplicate: true` and nothing new is created.

        On upload the vault reads the document's period, institution and account
        hints, and proposes a matching account with a confidence score. It does NOT
        link the statement to that account — linking is a human decision made in
        Settings -> Statement Vault. Report the suggestion; don't claim the link.

        Provide the file as base64 in `content_base64`. Maximum size is
        #{AccountStatement::MAX_FILE_SIZE / 1.megabyte} MB.

        Example:

        ```
        upload_account_statement({
          filename: "private-bank_2026-03-31_monthly-statement.pdf",
          content_base64: "JVBERi0xLjcK..."
        })
        ```
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[filename content_base64],
      properties: {
        filename: {
          type: "string",
          description: "Filename including extension. Must be one of: #{AccountStatement::ACCEPTED_FILE_EXTENSIONS.join(", ")}."
        },
        content_base64: {
          type: "string",
          description: "The document's raw bytes, base64-encoded."
        },
        account_id: {
          type: "string",
          description: "Optional account UUID to link the statement to on upload. Only pass this when the user has told you which account the document belongs to — otherwise omit it and let the vault suggest a match for the user to confirm."
        }
      }
    )
  end

  def call(params = {})
    return not_a_statement_manager unless statement_manager?

    filename = params["filename"].to_s.strip
    return error("filename_required", "Please provide a filename with an extension.") if filename.blank?

    unless AccountStatement::ACCEPTED_FILE_EXTENSIONS.include?(File.extname(filename).downcase)
      return error(
        "unsupported_file_type",
        "The Statement Vault accepts #{AccountStatement::ACCEPTED_FILE_EXTENSIONS.join(", ")} files only.",
        accepted_extensions: AccountStatement::ACCEPTED_FILE_EXTENSIONS
      )
    end

    content = decode_content(params["content_base64"])
    return error("invalid_content", "content_base64 could not be decoded as base64.") if content.nil?
    return error("empty_file", "The decoded file is empty.") if content.empty?

    if content.bytesize > AccountStatement::MAX_FILE_SIZE
      return error(
        "file_too_large",
        "The file is #{content.bytesize} bytes; the maximum is #{AccountStatement::MAX_FILE_SIZE} bytes."
      )
    end

    account = nil
    if params["account_id"].present?
      account = family.accounts.writable_by(user).find_by(id: params["account_id"]) if valid_uuid?(params["account_id"])

      unless account
        return error(
          "account_not_found",
          "No writable account matched that account_id. Omit account_id to upload the statement unlinked and let the vault suggest a match."
        )
      end
    end

    prepared = AccountStatement.prepare_upload!(upload_for(content, filename))
    statement = AccountStatement.create_from_prepared_upload!(family: family, account: account, prepared_upload: prepared)

    {
      success: true,
      duplicate: false,
      statement: statement_payload(statement),
      message: "Stored #{statement.filename} in the Statement Vault."
    }
  rescue AccountStatement::DuplicateUploadError => e
    duplicate_response(e.statement)
  rescue AccountStatement::InvalidUploadError
    error(
      "invalid_file",
      "The file failed validation: its contents don't match its extension, or it isn't a readable #{AccountStatement::ACCEPTED_FILE_EXTENSIONS.join("/")} document."
    )
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  rescue => e
    # The shared upload path can raise from content sniffing, storage or a
    # validation hook. The agent gets a fixed message, never the exception text:
    # a storage failure can carry bucket names, object keys, paths or request
    # details, and this response crosses out to an external client. Diagnostics
    # stay in the server log.
    Rails.logger.error("[UploadAccountStatement] #{e.class}: #{e.message}")
    error("upload_failed", "The statement could not be stored due to an unexpected error. It has been logged for the administrator.")
  end

  private
    # The existing copy may be filed against an account this user cannot see, so
    # the dedup result is reported without the details that would disclose it.
    def duplicate_response(statement)
      if statement.viewable_by?(user)
        {
          success: true,
          duplicate: true,
          statement: statement_payload(statement),
          message: "This document is already in the vault (same SHA-256). Returning the existing statement; nothing was created."
        }
      else
        {
          success: true,
          duplicate: true,
          statement: { content_sha256: statement.content_sha256 },
          message: "This document is already in the vault, filed against an account this user cannot see. Nothing was created."
        }
      end
    end

    # Whitespace is stripped because agents routinely wrap long base64 across
    # lines, and the urlsafe alphabet is translated to the standard one because
    # they sometimes emit it. Decoding stays strict after that: Base64.decode64
    # quietly discards characters it doesn't understand, which would archive
    # corrupted bytes under a hash that looks perfectly legitimate.
    def decode_content(value)
      return nil if value.blank?

      normalized = value.to_s.gsub(/\s+/, "").tr("-_", "+/")
      normalized += "=" * ((4 - normalized.length % 4) % 4)

      Base64.strict_decode64(normalized)
    rescue ArgumentError
      nil
    end

    # AccountStatement.prepare_upload! expects an uploaded-file-like object so it
    # can stream, size-check and sniff the content type. Reusing it (rather than
    # building a PreparedUpload by hand) keeps the MCP path under exactly the same
    # validations as the web upload form. Content type is left nil on purpose so
    # the vault sniffs it from the bytes rather than trusting the caller.
    def upload_for(content, filename)
      DecodedUpload.new(StringIO.new(content), filename)
    end

    class DecodedUpload
      attr_reader :original_filename, :content_type

      def initialize(io, filename, content_type = nil)
        @io = io
        @original_filename = filename
        @content_type = content_type
      end

      def read(*args)
        @io.read(*args)
      end

      def rewind
        @io.rewind
      end

      def size
        @io.size
      end
    end
end
