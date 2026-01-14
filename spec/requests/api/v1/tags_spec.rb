# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "Api::V1::Tags", type: :request do
  let(:family) { Family.create!(name: "Test Family") }
  let(:user) do
    family.users.create!(
      email: "test@example.com",
      password: "password123",
      first_name: "Test",
      last_name: "User"
    )
  end

  let(:oauth_application) do
    Doorkeeper::Application.create!(
      name: "Test App",
      redirect_uri: "https://example.com/callback",
      scopes: "read read_write"
    )
  end

  let(:read_token) do
    Doorkeeper::AccessToken.create!(
      application: oauth_application,
      resource_owner_id: user.id,
      scopes: "read"
    )
  end

  let(:read_write_token) do
    Doorkeeper::AccessToken.create!(
      application: oauth_application,
      resource_owner_id: user.id,
      scopes: "read_write"
    )
  end

  let(:Authorization) { "Bearer #{read_token.token}" }

  # Create test tag
  let!(:existing_tag) do
    family.tags.create!(name: "Existing Tag", color: "#3b82f6")
  end

  path "/api/v1/tags" do
    get "List all tags" do
      tags "Tags"
      description "Returns all tags belonging to the family"
      operationId "listTags"
      produces "application/json"
      security [ { bearerAuth: [] } ]

      parameter name: :Authorization,
                in: :header,
                type: :string,
                required: true,
                description: "Bearer token"

      response "200", "tags retrieved successfully" do
        schema type: :array,
               items: {
                 type: :object,
                 properties: {
                   id: { type: :string, format: :uuid },
                   name: { type: :string },
                   color: { type: :string },
                   created_at: { type: :string, format: "date-time" },
                   updated_at: { type: :string, format: "date-time" }
                 },
                 required: %w[id name color created_at updated_at]
               }

        run_test! do |response|
          tags = JSON.parse(response.body)
          expect(tags).to be_an(Array)
          expect(tags.length).to be >= 1
          expect(tags.first).to include("id", "name", "color")
        end
      end

      response "401", "unauthorized" do
        let(:Authorization) { "Bearer invalid_token" }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
        end
      end
    end

    post "Create a new tag" do
      tags "Tags"
      description "Creates a new tag for the family"
      operationId "createTag"
      consumes "application/json"
      produces "application/json"
      security [ { bearerAuth: [] } ]

      parameter name: :Authorization,
                in: :header,
                type: :string,
                required: true,
                description: "Bearer token with read_write scope"

      parameter name: :tag,
                in: :body,
                schema: {
                  type: :object,
                  properties: {
                    tag: {
                      type: :object,
                      properties: {
                        name: { type: :string },
                        color: { type: :string }
                      },
                      required: %w[name]
                    }
                  }
                }

      let(:Authorization) { "Bearer #{read_write_token.token}" }

      response "201", "tag created successfully" do
        schema type: :object,
               properties: {
                 id: { type: :string, format: :uuid },
                 name: { type: :string },
                 color: { type: :string },
                 created_at: { type: :string, format: "date-time" },
                 updated_at: { type: :string, format: "date-time" }
               },
               required: %w[id name color created_at updated_at]

        let(:tag) { { tag: { name: "New Tag", color: "#4da568" } } }

        run_test! do |response|
          created_tag = JSON.parse(response.body)
          expect(created_tag["name"]).to eq("New Tag")
          expect(created_tag["color"]).to eq("#4da568")
        end
      end

      response "201", "tag created with auto-assigned color" do
        let(:tag) { { tag: { name: "Auto Color Tag" } } }

        run_test! do |response|
          created_tag = JSON.parse(response.body)
          expect(created_tag["name"]).to eq("Auto Color Tag")
          expect(created_tag["color"]).to be_present
        end
      end

      response "422", "validation failed - duplicate name" do
        let(:tag) { { tag: { name: "Existing Tag" } } }

        run_test! do |response|
          expect(response).to have_http_status(:unprocessable_entity)
        end
      end

      response "401", "unauthorized - read scope insufficient" do
        let(:Authorization) { "Bearer #{read_token.token}" }
        let(:tag) { { tag: { name: "Unauthorized Tag" } } }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
        end
      end
    end
  end

  path "/api/v1/tags/{id}" do
    get "Get a specific tag" do
      tags "Tags"
      description "Returns a single tag by ID"
      operationId "getTag"
      produces "application/json"
      security [ { bearerAuth: [] } ]

      parameter name: :Authorization,
                in: :header,
                type: :string,
                required: true,
                description: "Bearer token"

      parameter name: :id,
                in: :path,
                type: :string,
                format: :uuid,
                required: true,
                description: "Tag ID"

      response "200", "tag retrieved successfully" do
        schema type: :object,
               properties: {
                 id: { type: :string, format: :uuid },
                 name: { type: :string },
                 color: { type: :string },
                 created_at: { type: :string, format: "date-time" },
                 updated_at: { type: :string, format: "date-time" }
               },
               required: %w[id name color created_at updated_at]

        let(:id) { existing_tag.id }

        run_test! do |response|
          tag = JSON.parse(response.body)
          expect(tag["id"]).to eq(existing_tag.id)
          expect(tag["name"]).to eq("Existing Tag")
        end
      end

      response "404", "tag not found" do
        let(:id) { "00000000-0000-0000-0000-000000000000" }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    patch "Update a tag" do
      tags "Tags"
      description "Updates an existing tag"
      operationId "updateTag"
      consumes "application/json"
      produces "application/json"
      security [ { bearerAuth: [] } ]

      parameter name: :Authorization,
                in: :header,
                type: :string,
                required: true,
                description: "Bearer token with read_write scope"

      parameter name: :id,
                in: :path,
                type: :string,
                format: :uuid,
                required: true,
                description: "Tag ID"

      parameter name: :tag,
                in: :body,
                schema: {
                  type: :object,
                  properties: {
                    tag: {
                      type: :object,
                      properties: {
                        name: { type: :string },
                        color: { type: :string }
                      }
                    }
                  }
                }

      let(:Authorization) { "Bearer #{read_write_token.token}" }

      response "200", "tag updated successfully" do
        let(:id) { existing_tag.id }
        let(:tag) { { tag: { name: "Updated Tag", color: "#db5a54" } } }

        run_test! do |response|
          updated_tag = JSON.parse(response.body)
          expect(updated_tag["name"]).to eq("Updated Tag")
          expect(updated_tag["color"]).to eq("#db5a54")
        end
      end

      response "200", "tag partially updated" do
        let(:id) { existing_tag.id }
        let(:tag) { { tag: { color: "#eb5429" } } }

        run_test! do |response|
          updated_tag = JSON.parse(response.body)
          expect(updated_tag["name"]).to eq("Existing Tag")
          expect(updated_tag["color"]).to eq("#eb5429")
        end
      end

      response "404", "tag not found" do
        let(:id) { "00000000-0000-0000-0000-000000000000" }
        let(:tag) { { tag: { name: "Not Found" } } }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response "401", "unauthorized - read scope insufficient" do
        let(:Authorization) { "Bearer #{read_token.token}" }
        let(:id) { existing_tag.id }
        let(:tag) { { tag: { name: "Unauthorized Update" } } }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
        end
      end
    end

    delete "Delete a tag" do
      tags "Tags"
      description "Permanently deletes a tag"
      operationId "deleteTag"
      security [ { bearerAuth: [] } ]

      parameter name: :Authorization,
                in: :header,
                type: :string,
                required: true,
                description: "Bearer token with read_write scope"

      parameter name: :id,
                in: :path,
                type: :string,
                format: :uuid,
                required: true,
                description: "Tag ID"

      let(:Authorization) { "Bearer #{read_write_token.token}" }

      response "204", "tag deleted successfully" do
        let!(:tag_to_delete) { family.tags.create!(name: "Delete Me", color: "#c44fe9") }
        let(:id) { tag_to_delete.id }

        run_test! do |response|
          expect(response).to have_http_status(:no_content)
          expect(Tag.find_by(id: tag_to_delete.id)).to be_nil
        end
      end

      response "404", "tag not found" do
        let(:id) { "00000000-0000-0000-0000-000000000000" }

        run_test! do |response|
          expect(response).to have_http_status(:not_found)
        end
      end

      response "401", "unauthorized - read scope insufficient" do
        let(:Authorization) { "Bearer #{read_token.token}" }
        let(:id) { existing_tag.id }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
        end
      end
    end
  end
end
