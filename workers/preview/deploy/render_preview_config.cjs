const fs = require("node:fs");

const IMAGE_FIELD_PATTERN = /^(\s*image\s*=\s*)"([^"]*)"(\s*(?:#.*)?)$/gm;
const REGISTRY_IMAGE_REF_PATTERN =
  /^registry\.cloudflare\.com\/([A-Za-z0-9_-]+)\/(sure-preview-pr-([1-9][0-9]*):([a-f0-9]{40}))$/;
const REGISTRY_IMAGE_REF_SCAN_PATTERN =
  /registry\.cloudflare\.com\/[A-Za-z0-9_-]+\/sure-preview-pr-[1-9][0-9]*:[a-f0-9]{40}/g;

function expectedImageTag({ prNumber, headSha }) {
  if (!/^[1-9][0-9]*$/.test(String(prNumber || ""))) {
    throw new Error("Expected a numeric preview PR number");
  }

  if (!/^[a-f0-9]{40}$/.test(String(headSha || ""))) {
    throw new Error("Expected a 40-character preview head SHA");
  }

  return `sure-preview-pr-${prNumber}:${headSha}`;
}

function validateRegistryImageRef(imageRef, { accountId, prNumber, headSha }) {
  const match = REGISTRY_IMAGE_REF_PATTERN.exec(imageRef || "");
  if (!match) {
    throw new Error("Expected a Cloudflare registry image reference");
  }

  const expectedTag = expectedImageTag({ prNumber, headSha });
  if (match[2] !== expectedTag) {
    throw new Error("Cloudflare registry image reference does not match this preview artifact");
  }

  if (accountId && match[1] !== accountId) {
    throw new Error("Cloudflare registry image reference account does not match this workflow");
  }

  return imageRef;
}

function renderPreviewConfig(source, imageRef, options) {
  validateRegistryImageRef(imageRef, options);

  const matches = [...source.matchAll(IMAGE_FIELD_PATTERN)];
  if (matches.length === 0) {
    throw new Error("Expected wrangler.toml source to contain an image entry");
  }

  if (matches.length > 1) {
    throw new Error("Expected wrangler.toml source to contain exactly one image entry");
  }

  return source.replace(IMAGE_FIELD_PATTERN, `$1${JSON.stringify(imageRef)}$3`);
}

function findRegistryImageRef(log, options) {
  const matches = [...new Set(log.match(REGISTRY_IMAGE_REF_SCAN_PATTERN) || [])];
  const matchedRef = matches.find((candidate) => {
    try {
      validateRegistryImageRef(candidate, options);
      return true;
    } catch {
      return false;
    }
  });

  return matchedRef || "";
}

function envOptions() {
  return {
    accountId: process.env.CLOUDFLARE_ACCOUNT_ID,
    prNumber: process.env.PR_NUMBER,
    headSha: process.env.HEAD_SHA,
  };
}

function runCli() {
  const command = process.argv[2];

  if (command === "render") {
    const sourcePath = process.argv[3];
    const destinationPath = process.argv[4];
    const imageRef = process.env.PREVIEW_IMAGE_REF;

    if (!sourcePath || !destinationPath) {
      throw new Error("Usage: render_preview_config.cjs render <source> <destination>");
    }

    const rendered = renderPreviewConfig(fs.readFileSync(sourcePath, "utf8"), imageRef, envOptions());
    fs.writeFileSync(destinationPath, rendered);
    return;
  }

  if (command === "find") {
    const logPath = process.argv[3];
    if (!logPath) {
      throw new Error("Usage: render_preview_config.cjs find <wrangler-log>");
    }

    process.stdout.write(findRegistryImageRef(fs.readFileSync(logPath, "utf8"), envOptions()));
    return;
  }

  throw new Error(`Unknown command ${command || ""}`);
}

if (require.main === module) {
  runCli();
}

module.exports = {
  findRegistryImageRef,
  renderPreviewConfig,
  validateRegistryImageRef,
};
