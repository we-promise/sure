const assert = require("node:assert/strict");
const { describe, it } = require("node:test");

const {
  findRegistryImageRef,
  renderPreviewConfig,
  validateRegistryImageRef,
} = require("../../../workers/preview/deploy/render_preview_config.cjs");

const options = {
  accountId: "account_123",
  prNumber: "2160",
  headSha: "3f013c4d9193ff111295c89a6f833d59bd69d91e",
};
const imageRef =
  "registry.cloudflare.com/account_123/sure-preview-pr-2160:3f013c4d9193ff111295c89a6f833d59bd69d91e";

describe("renderPreviewConfig", () => {
  it("renders exactly one trusted TOML image entry to a registry reference", () => {
    const source = [
      'name = "sure-preview-2160"',
      "",
      "[[containers]]",
      'image = "../../Dockerfile.preview"',
      'class_name = "RailsContainer"',
      "",
    ].join("\n");

    const rendered = renderPreviewConfig(source, imageRef, options);

    assert.ok(rendered.includes(`image = "${imageRef}"`));
    assert.doesNotMatch(rendered, /Dockerfile\.preview/);
  });

  it("rejects missing image entries", () => {
    assert.throws(
      () => renderPreviewConfig('name = "sure-preview-2160"\n', imageRef, options),
      /contain an image entry/
    );
  });

  it("rejects duplicate image entries", () => {
    const source = [
      "[[containers]]",
      'image = "../../Dockerfile.preview"',
      "",
      "[[containers]]",
      'image = "../../OtherDockerfile"',
      "",
    ].join("\n");

    assert.throws(() => renderPreviewConfig(source, imageRef, options), /exactly one image entry/);
  });

  it("rejects local Docker tags as deploy image refs", () => {
    assert.throws(
      () => renderPreviewConfig('image = "../../Dockerfile.preview"\n', "my-local-image:latest", options),
      /Cloudflare registry image reference/
    );
  });
});

describe("validateRegistryImageRef", () => {
  it("accepts the expected registry ref", () => {
    assert.equal(validateRegistryImageRef(imageRef, options), imageRef);
  });

  it("rejects registry refs for another PR", () => {
    const wrongPr =
      "registry.cloudflare.com/account_123/sure-preview-pr-2161:3f013c4d9193ff111295c89a6f833d59bd69d91e";

    assert.throws(() => validateRegistryImageRef(wrongPr, options), /does not match this preview artifact/);
  });

  it("rejects registry refs for another account", () => {
    const wrongAccount =
      "registry.cloudflare.com/account_456/sure-preview-pr-2160:3f013c4d9193ff111295c89a6f833d59bd69d91e";

    assert.throws(() => validateRegistryImageRef(wrongAccount, options), /account does not match/);
  });
});

describe("findRegistryImageRef", () => {
  it("extracts the expected registry image ref from wrangler output", () => {
    const log = [
      "Pushing image layers",
      "Published registry.cloudflare.com/account_123/sure-preview-pr-2160:3f013c4d9193ff111295c89a6f833d59bd69d91e",
      "Done",
    ].join("\n");

    assert.equal(findRegistryImageRef(log, options), imageRef);
  });

  it("ignores registry refs that do not match this preview artifact", () => {
    const log =
      "Published registry.cloudflare.com/account_123/sure-preview-pr-2161:3f013c4d9193ff111295c89a6f833d59bd69d91e";

    assert.equal(findRegistryImageRef(log, options), "");
  });
});
