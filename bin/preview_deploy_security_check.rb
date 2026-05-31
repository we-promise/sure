#!/usr/bin/env ruby
# frozen_string_literal: true

%w[json pathname yaml].each { |library| require library }

ROOT = File.expand_path("..", __dir__)
PREVIEW_WORKFLOW_PATH = File.join(ROOT, ".github/workflows/preview-deploy.yml")
PR_WORKFLOW_PATH = File.join(ROOT, ".github/workflows/pr.yml")
LOCKFILE_PATH = File.join(ROOT, "workers/preview/package-lock.json")
RESOLVER_PATH = File.join(ROOT, "workers/preview/deploy/resolve_preview_request.cjs")
PINNED_ACTION = /\A[^@\s]+@[a-f0-9]{40}\z/
EXPECTED_ACTION_PINS = {
  "actions/checkout" => "93cb6efe18208431cddfb8368fd83d5badbf9bfd", # v5
  "actions/download-artifact" => "018cc2cf5baa6db3ef3c5f8a56943fffe632ef53", # v6
  "actions/github-script" => "f28e40c7f34bde8b3046d885e986cb6290c5673b", # v7
  "actions/setup-node" => "48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e", # v6
  "actions/upload-artifact" => "b7c566a772e6b6bfb58ed0dc250532a479d7789f" # v6
}.freeze
INLINE_SECRET_EXPRESSION = /\$\{\{\s*secrets\s*(?:\.|\[)/i
INLINE_PR_EXPRESSION = /
  \$\{\{\s*
  github\s*
  (?:\.\s*event|\[\s*['"]event['"]\s*\])\s*
  (?:\.\s*pull_request|\[\s*['"]pull_request['"]\s*\])
/ix
PR_CONTROLLED_WORKDIR = %r{\A(?:pr|workers/preview)(?:/|\z)}
GITHUB_WORKSPACE_PREFIX = %r{
  \A
  (?:
    \$GITHUB_WORKSPACE |
    \$\{\{\s*github\s*(?:\.\s*workspace|\[\s*['"]workspace['"]\s*\])\s*\}\}
  )
  (?:/|\z)
}ix
EXPECTED_TOP_LEVEL_PERMISSIONS = { "contents" => "read" }.freeze
EXPECTED_GATE_PERMISSIONS = { "actions" => "read", "contents" => "read", "pull-requests" => "read" }.freeze
EXPECTED_IMAGE_PERMISSIONS = { "contents" => "read" }.freeze
EXPECTED_DEPLOYMENT_PERMISSIONS = {
  "contents" => "read",
  "deployments" => "write"
}.freeze
EXPECTED_DEPLOY_PERMISSIONS = {
  "actions" => "read",
  "contents" => "read"
}.freeze
EXPECTED_COMMENT_PERMISSIONS = {
  "contents" => "read",
  "pull-requests" => "write"
}.freeze
EXPECTED_DEPLOY_SECRET_ENV = %w[CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN CLOUDFLARE_WORKERS_SUBDOMAIN].freeze
EXPECTED_PUSH_SECRET_ENV = %w[CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN].freeze
REQUIRED_PREPARE_LINES = [
  'cp trusted/workers/preview/package.json "$preview_dir/package.json"',
  'cp trusted/workers/preview/package-lock.json "$preview_dir/package-lock.json"',
  'cp trusted/workers/preview/tsconfig.json "$preview_dir/tsconfig.json"',
  'cp trusted/workers/preview/wrangler.toml "$preview_dir/wrangler.toml"',
  'cp -R trusted/workers/preview/src "$preview_dir/src"',
  "npm ci --ignore-scripts --no-audit --no-fund"
].freeze
REQUIRED_IMAGE_BUILD_LINES = [
  "docker build",
  "--platform linux/amd64",
  '--build-arg "BUILD_COMMIT_SHA=${HEAD_SHA}"',
  "-f Dockerfile.preview",
  '-t "${IMAGE_TAG}"',
  'docker save "${IMAGE_TAG}" | gzip -1 > "$image_archive"',
  'sha256sum "$image_archive"',
  "sure-preview-image.manifest.json",
  'ARCHIVE_SHA256="$archive_sha256" IMAGE_ID="$image_id" node - "$manifest_file"',
  "JSON.stringify(manifest, null, 2)",
  'jq -e . "$manifest_file"'
].freeze

def fail_check(message)
  warn "preview-deploy security check failed: #{message}"
  exit 1
end

def assert(value, message)
  fail_check(message) unless value
end

def workflow_on(workflow)
  workflow["on"] || workflow[true] || fail_check("workflow is missing on trigger")
end

def step!(steps, name)
  steps.find { |step| step["name"] == name } || fail_check("missing #{name.inspect} step")
end

def run(step)
  step.fetch("run", "")
end

def step_body(step)
  [ run(step), step.dig("with", "script") ].compact.join("\n")
end

def env_hash(node)
  node.fetch("env", {})
end

def assert_run_includes(step, *needles)
  script = step_body(step)
  needles.each { |needle| assert(script.include?(needle), "#{step["name"]} must include #{needle.inspect}") }
  script
end

def normalized_working_directory(value)
  path = value.to_s.strip.sub(GITHUB_WORKSPACE_PREFIX, "")
  normalized = Pathname.new(path).cleanpath.to_s

  normalized == "." ? "" : normalized
end

def environment_name(job)
  environment = job["environment"]
  environment.is_a?(Hash) ? environment["name"] : environment
end

def assert_pinned_actions!(steps)
  steps.each do |step|
    uses = step["uses"]
    next unless uses
    next if uses.start_with?("./")

    assert(uses.match?(PINNED_ACTION), "#{step["name"] || uses} must pin external actions")

    action, sha = uses.split("@", 2)
    expected_sha = EXPECTED_ACTION_PINS[action]
    assert(sha == expected_sha, "#{step["name"] || uses} must pin #{action} to #{expected_sha}") if expected_sha
  end
end

def assert_no_inline_expressions!(steps)
  inline_scripts = steps.flat_map { |step| [ run(step), step.dig("with", "script") ] }.compact.join("\n")
  assert(!inline_scripts.match?(INLINE_SECRET_EXPRESSION), "secrets must enter scripts through env")
  assert(!inline_scripts.match?(INLINE_PR_EXPRESSION), "PR fields must enter scripts through env")
end

def assert_secret_env_sources!(step, expected_keys)
  env = step.fetch("env")

  assert(env.keys.sort == expected_keys, "#{step["name"]} secret env keys must be #{expected_keys.inspect}")
  assert(expected_keys.all? { |name| env.fetch(name).start_with?("${{ secrets.") }, "#{step["name"]} secret env must be sourced from GitHub secrets")
end

preview_workflow = YAML.safe_load_file(PREVIEW_WORKFLOW_PATH, aliases: true)
pr_workflow = YAML.safe_load_file(PR_WORKFLOW_PATH, aliases: true)
lockfile = JSON.parse(File.read(LOCKFILE_PATH))
resolver_script = File.read(RESOLVER_PATH)

preview_on = workflow_on(preview_workflow)
pr_on = workflow_on(pr_workflow)
preview_jobs = preview_workflow.fetch("jobs")
pr_jobs = pr_workflow.fetch("jobs")
gate_job = preview_jobs.fetch("preview-gate")
image_job = pr_jobs.fetch("preview_image")
deployment_record_job = preview_jobs.fetch("deployment_record")
deploy_job = preview_jobs.fetch("deploy-preview")
deployment_status_job = preview_jobs.fetch("deployment_status")
preview_comment_job = preview_jobs.fetch("preview_comment")
gate_steps = gate_job.fetch("steps")
image_steps = image_job.fetch("steps")
deployment_record_steps = deployment_record_job.fetch("steps")
deploy_steps = deploy_job.fetch("steps")
deployment_status_steps = deployment_status_job.fetch("steps")
preview_comment_steps = preview_comment_job.fetch("steps")
deploy_step_names = deploy_steps.map { |step| step["name"] }
wrangler = lockfile.fetch("packages").fetch("node_modules/wrangler")

gate_trusted_checkout = step!(gate_steps, "Checkout trusted preview resolver")
resolve_preview = step!(gate_steps, "Resolve preview request")

pr_checkout = step!(image_steps, "Checkout PR code")
build_image = step!(image_steps, "Build preview image without secrets")
upload_image = step!(image_steps, "Upload preview image artifact")

create_deployment = step!(deployment_record_steps, "Create GitHub Deployment")
trusted_checkout = step!(deploy_steps, "Checkout trusted preview tooling")
download_artifact = step!(deploy_steps, "Download preview image artifact")
verify_checksum = step!(deploy_steps, "Verify preview image artifact checksum")
prepare = step!(deploy_steps, "Prepare trusted preview deploy workspace")
load_image = step!(deploy_steps, "Load preview image artifact")
push_image = step!(deploy_steps, "Push preview image to Cloudflare registry")
configure_image = step!(deploy_steps, "Configure trusted preview image reference")
deploy = step!(deploy_steps, "Deploy to Cloudflare Containers")
warm_preview = step!(deploy_steps, "Warm preview container")
collect_diagnostics = step!(deploy_steps, "Collect preview diagnostics")
upload_diagnostics = step!(deploy_steps, "Upload preview diagnostics")
update_deployment_status = step!(deployment_status_steps, "Update Deployment Status")
comment_on_pr = step!(preview_comment_steps, "Comment on PR")

[
  [ "preview trigger", preview_on.keys, [ "workflow_run" ] ],
  [ "preview trigger workflows", preview_on.dig("workflow_run", "workflows"), [ "Pull Request" ] ],
  [ "preview trigger types", preview_on.dig("workflow_run", "types"), [ "completed" ] ],
  [ "preview top-level permissions", preview_workflow.fetch("permissions"), EXPECTED_TOP_LEVEL_PERMISSIONS ],
  [ "preview workflow jobs", preview_jobs.keys, [ "preview-gate", "deployment_record", "deploy-preview", "deployment_status", "preview_comment" ] ],
  [ "PR workflow trigger types", pr_on.dig("pull_request", "types"), %w[opened synchronize reopened labeled] ],
  [ "PR workflow paths-ignore", pr_on.dig("pull_request", "paths-ignore"), [ "charts/**" ] ],
  [ "PR workflow permissions", pr_workflow.fetch("permissions"), EXPECTED_TOP_LEVEL_PERMISSIONS ],
  [ "PR workflow jobs", pr_jobs.keys, [ "ci", "preview_image" ] ],
  [ "preview gate permissions", gate_job.fetch("permissions"), EXPECTED_GATE_PERMISSIONS ],
  [ "preview gate timeout", gate_job.fetch("timeout-minutes"), 10 ],
  [ "preview gate should_deploy output", gate_job.dig("outputs", "should_deploy"), "${{ steps.preview.outputs.should_deploy }}" ],
  [ "preview gate artifact output", gate_job.dig("outputs", "artifact_name"), "${{ steps.preview.outputs.artifact_name }}" ],
  [ "preview gate head output", gate_job.dig("outputs", "head_sha"), "${{ steps.preview.outputs.head_sha }}" ],
  [ "preview gate fork output", gate_job.dig("outputs", "is_fork"), "${{ steps.preview.outputs.is_fork }}" ],
  [ "preview gate PR output", gate_job.dig("outputs", "pr_number"), "${{ steps.preview.outputs.pr_number }}" ],
  [ "preview image needs", image_job.fetch("needs"), "ci" ],
  [ "preview image permissions", image_job.fetch("permissions"), EXPECTED_IMAGE_PERMISSIONS ],
  [ "preview image timeout", image_job.fetch("timeout-minutes"), 30 ],
  [ "image PR_NUMBER env", image_job.dig("env", "PR_NUMBER"), "${{ github.event.pull_request.number }}" ],
  [ "image HEAD_SHA env", image_job.dig("env", "HEAD_SHA"), "${{ github.event.pull_request.head.sha }}" ],
  [ "image tag env", image_job.dig("env", "IMAGE_TAG"), "sure-preview-pr-${{ github.event.pull_request.number }}:${{ github.event.pull_request.head.sha }}" ],
  [ "deployment record needs", deployment_record_job.fetch("needs"), "preview-gate" ],
  [ "deployment record if", deployment_record_job.fetch("if"), "needs.preview-gate.outputs.should_deploy == 'true'" ],
  [ "deployment record permissions", deployment_record_job.fetch("permissions"), EXPECTED_DEPLOYMENT_PERMISSIONS ],
  [ "deployment record timeout", deployment_record_job.fetch("timeout-minutes"), 5 ],
  [ "deployment record output", deployment_record_job.dig("outputs", "deployment_id"), "${{ steps.deployment.outputs.result }}" ],
  [ "deployment record HEAD_SHA env", deployment_record_job.dig("env", "HEAD_SHA"), "${{ needs.preview-gate.outputs.head_sha }}" ],
  [ "deployment record IS_FORK env", deployment_record_job.dig("env", "IS_FORK"), "${{ needs.preview-gate.outputs.is_fork }}" ],
  [ "deployment record PR_NUMBER env", deployment_record_job.dig("env", "PR_NUMBER"), "${{ needs.preview-gate.outputs.pr_number }}" ],
  [ "deploy job needs", deploy_job.fetch("needs"), [ "preview-gate", "deployment_record" ] ],
  [ "deploy job permissions", deploy_job.fetch("permissions"), EXPECTED_DEPLOY_PERMISSIONS ],
  [ "deploy job environment", environment_name(deploy_job), "preview" ],
  [ "deploy job timeout", deploy_job.fetch("timeout-minutes"), 45 ],
  [ "deploy preview output", deploy_job.dig("outputs", "preview_url"), "${{ steps.deploy.outputs.preview_url }}" ],
  [ "deploy concurrency group", deploy_job.dig("concurrency", "group"), "preview-deploy-${{ needs.preview-gate.outputs.pr_number }}" ],
  [ "deploy concurrency cancellation", deploy_job.dig("concurrency", "cancel-in-progress"), true ],
  [ "deploy ARTIFACT_NAME env", deploy_job.dig("env", "ARTIFACT_NAME"), "${{ needs.preview-gate.outputs.artifact_name }}" ],
  [ "deploy HEAD_SHA env", deploy_job.dig("env", "HEAD_SHA"), "${{ needs.preview-gate.outputs.head_sha }}" ],
  [ "deploy IS_FORK env", deploy_job.dig("env", "IS_FORK"), "${{ needs.preview-gate.outputs.is_fork }}" ],
  [ "deploy PR_NUMBER env", deploy_job.dig("env", "PR_NUMBER"), "${{ needs.preview-gate.outputs.pr_number }}" ],
  [ "deployment status needs", deployment_status_job.fetch("needs"), [ "preview-gate", "deployment_record", "deploy-preview" ] ],
  [ "deployment status permissions", deployment_status_job.fetch("permissions"), EXPECTED_DEPLOYMENT_PERMISSIONS ],
  [ "deployment status timeout", deployment_status_job.fetch("timeout-minutes"), 5 ],
  [ "deployment status DEPLOYMENT_ID env", deployment_status_job.dig("env", "DEPLOYMENT_ID"), "${{ needs.deployment_record.outputs.deployment_id }}" ],
  [ "deployment status DEPLOY_RESULT env", deployment_status_job.dig("env", "DEPLOY_RESULT"), "${{ needs.deploy-preview.result }}" ],
  [ "deployment status PREVIEW_URL env", deployment_status_job.dig("env", "PREVIEW_URL"), "${{ needs.deploy-preview.outputs.preview_url }}" ],
  [ "preview comment needs", preview_comment_job.fetch("needs"), [ "preview-gate", "deploy-preview" ] ],
  [ "preview comment if", preview_comment_job.fetch("if"), "needs.deploy-preview.result == 'success'" ],
  [ "preview comment permissions", preview_comment_job.fetch("permissions"), EXPECTED_COMMENT_PERMISSIONS ],
  [ "preview comment timeout", preview_comment_job.fetch("timeout-minutes"), 5 ],
  [ "preview comment HEAD_SHA env", preview_comment_job.dig("env", "HEAD_SHA"), "${{ needs.preview-gate.outputs.head_sha }}" ],
  [ "preview comment PR_NUMBER env", preview_comment_job.dig("env", "PR_NUMBER"), "${{ needs.preview-gate.outputs.pr_number }}" ],
  [ "preview comment PREVIEW_URL env", preview_comment_job.dig("env", "PREVIEW_URL"), "${{ needs.deploy-preview.outputs.preview_url }}" ],
  [ "gate trusted checkout ref", gate_trusted_checkout.dig("with", "ref"), "${{ github.event.repository.default_branch }}" ],
  [ "gate trusted checkout path", gate_trusted_checkout.dig("with", "path"), "trusted-preview-resolver" ],
  [ "gate trusted checkout credentials", gate_trusted_checkout.dig("with", "persist-credentials"), false ],
  [ "PR checkout credentials", pr_checkout.dig("with", "persist-credentials"), false ],
  [ "upload artifact name", upload_image.dig("with", "name"), "preview-image-pr-${{ env.PR_NUMBER }}-${{ env.HEAD_SHA }}" ],
  [ "upload artifact retention", upload_image.dig("with", "retention-days"), 3 ],
  [ "trusted checkout ref", trusted_checkout.dig("with", "ref"), "${{ github.event.repository.default_branch }}" ],
  [ "trusted checkout path", trusted_checkout.dig("with", "path"), "trusted" ],
  [ "trusted checkout credentials", trusted_checkout.dig("with", "persist-credentials"), false ],
  [ "download artifact name", download_artifact.dig("with", "name"), "${{ env.ARTIFACT_NAME }}" ],
  [ "download artifact run id", download_artifact.dig("with", "run-id"), "${{ github.event.workflow_run.id }}" ],
  [ "download artifact token", download_artifact.dig("with", "github-token"), "${{ github.token }}" ],
  [ "download artifact path", download_artifact.dig("with", "path"), "${{ runner.temp }}/preview-image" ],
  [ "fork deployment record guard", create_deployment.fetch("if"), "env.IS_FORK == 'false'" ],
  [ "diagnostics upload name", upload_diagnostics.dig("with", "name"), "preview-diagnostics-pr-${{ env.PR_NUMBER }}-${{ env.HEAD_SHA }}" ],
  [ "diagnostics upload path", upload_diagnostics.dig("with", "path"), "${{ runner.temp }}/preview-diagnostics.json" ],
  [ "diagnostics upload retention", upload_diagnostics.dig("with", "retention-days"), 3 ],
  [ "Wrangler binary", wrangler.dig("bin", "wrangler"), "bin/wrangler.js" ]
].each { |label, actual, expected| assert(actual == expected, "#{label}: expected #{actual.inspect} to equal #{expected.inspect}") }

assert(pr_on.key?("pull_request"), "PR workflow must still run on pull_request")
assert(!preview_on.key?("pull_request_target"), "privileged preview deploy workflow must not run on pull_request_target")
assert(!preview_on.key?("pull_request"), "privileged preview deploy workflow must not run directly on pull_request")
assert(gate_job.fetch("if").include?("github.event.workflow_run.event == 'pull_request'"), "preview gate must only accept pull_request workflow runs")
assert(gate_job.fetch("if").include?("github.event.workflow_run.conclusion == 'success'"), "preview gate must only accept successful PR workflow runs")
assert(image_job.fetch("if").include?("preview-cf"), "preview image build must stay gated by preview-cf")
assert(deploy_job.fetch("if").include?("needs.preview-gate.outputs.should_deploy == 'true'"), "privileged preview deploy must depend on the gate output")
assert(deploy_job.fetch("if").include?("needs.deployment_record.result == 'success'"), "privileged preview deploy must require deployment record success or skip")
assert(deploy_job.fetch("if").include?("needs.deployment_record.result == 'skipped'"), "privileged preview deploy must allow skipped deployment records")
assert(deployment_status_job.fetch("if").include?("needs.preview-gate.outputs.is_fork == 'false'"), "deployment status job must only run for same-repository PRs")
assert(deployment_status_job.fetch("if").include?("needs.deployment_record.result == 'success'"), "deployment status job must require a created deployment")
assert(gate_job["environment"].nil?, "preview gate must not use a protected secret-bearing environment")
assert(image_job["environment"].nil?, "preview image build must not use a protected secret-bearing environment")
assert(deployment_record_job["environment"].nil?, "deployment record job must not use a protected secret-bearing environment")
assert(deployment_status_job["environment"].nil?, "deployment status job must not use a protected secret-bearing environment")
assert(preview_comment_job["environment"].nil?, "preview comment job must not use a protected secret-bearing environment")
assert(lockfile.dig("packages", "", "devDependencies", "wrangler"), "Wrangler must stay a root dev dependency")
assert(lockfile.fetch("lockfileVersion") >= 3, "preview tooling lockfile must preserve npm ci integrity metadata")
assert(wrangler.fetch("resolved").start_with?("https://registry.npmjs.org/wrangler/-/wrangler-"), "Wrangler must resolve from npm registry")
assert(wrangler.fetch("integrity").start_with?("sha512-"), "Wrangler lockfile entry must keep npm integrity metadata")
assert(gate_trusted_checkout.dig("with", "sparse-checkout").to_s.include?("workers/preview/deploy"), "trusted gate checkout must include preview resolver")
assert(trusted_checkout.dig("with", "sparse-checkout").to_s.include?("workers/preview"), "trusted checkout must include preview tooling")
assert(deploy_step_names.compact.uniq == deploy_step_names.compact, "workflow step names must stay unique for security checks")
assert([ gate_trusted_checkout, resolve_preview ].map { |step| gate_steps.index(step) }.each_cons(2).all? { |left, right| left < right }, "gate workflow steps must checkout trusted resolver before use")
assert([ trusted_checkout, download_artifact, verify_checksum, prepare, load_image, push_image, configure_image, deploy, warm_preview, collect_diagnostics, upload_diagnostics ].map { |step| deploy_steps.index(step) }.each_cons(2).all? { |left, right| left < right }, "deploy workflow steps must preserve safe cross-run artifact deploy order")
assert(deploy_steps.none? { |step| step["name"] == "Checkout PR code" }, "privileged deploy job must not checkout PR code")
assert(env_hash(deploy_job).keys.none? { |name| name.start_with?("CLOUDFLARE_") }, "Cloudflare secrets must not be job-wide")
assert(env_hash(gate_job).keys.none? { |name| name.start_with?("CLOUDFLARE_") }, "preview gate must not receive Cloudflare secrets")
assert(env_hash(image_job).keys.none? { |name| name.start_with?("CLOUDFLARE_") }, "preview image build must not receive Cloudflare secrets")
assert(env_hash(deployment_record_job).keys.none? { |name| name.start_with?("CLOUDFLARE_") }, "deployment record job must not receive Cloudflare secrets")
assert(env_hash(deployment_status_job).keys.none? { |name| name.start_with?("CLOUDFLARE_") }, "deployment status job must not receive Cloudflare secrets")
assert(env_hash(preview_comment_job).keys.none? { |name| name.start_with?("CLOUDFLARE_") }, "preview comment job must not receive Cloudflare secrets")
assert(upload_image.dig("with", "path").to_s.include?("sure-preview-image.tar.gz"), "preview image artifact must include the image archive")
assert(upload_image.dig("with", "path").to_s.include?("sure-preview-image.sha256"), "preview image artifact must include the checksum")
assert(upload_image.dig("with", "path").to_s.include?("sure-preview-image.manifest.json"), "preview image artifact must include the manifest")

assert_pinned_actions!(gate_steps)
assert_pinned_actions!(image_steps)
assert_pinned_actions!(deployment_record_steps)
assert_pinned_actions!(deploy_steps)
assert_pinned_actions!(deployment_status_steps)
assert_pinned_actions!(preview_comment_steps)
assert_no_inline_expressions!(gate_steps)
assert_no_inline_expressions!(image_steps)
assert_no_inline_expressions!(deployment_record_steps)
assert_no_inline_expressions!(deploy_steps)
assert_no_inline_expressions!(deployment_status_steps)
assert_no_inline_expressions!(preview_comment_steps)

all_steps = gate_steps + image_steps + deployment_record_steps + deploy_steps + deployment_status_steps + preview_comment_steps
assert(all_steps.none? { |step| env_hash(step).values.join("\n").match?(INLINE_SECRET_EXPRESSION) && ![ push_image, deploy ].include?(step) }, "only Cloudflare steps may reference GitHub secrets")
assert(deploy_steps.none? { |step| normalized_working_directory(step["working-directory"]).match?(PR_CONTROLLED_WORKDIR) }, "privileged deploy steps must not run from PR-controlled dirs")
assert(deploy_steps.none? { |step| run(step).include?("npx wrangler") }, "privileged deploy workflow must not use npx wrangler")
assert(deploy_steps.none? { |step| run(step).match?(/Dockerfile\.preview|docker build|docker save/) }, "privileged deploy job must not build PR Dockerfiles")
assert(deploy_steps.none? { |step| run(step).include?("${GITHUB_WORKSPACE}/pr") || run(step).include?(" pr/") }, "privileged deploy job must not reference PR checkout paths")
assert((deployment_record_steps + deployment_status_steps + preview_comment_steps).none? { |step| [ step["uses"], run(step) ].compact.join("\n").include?("download-artifact") }, "GitHub write jobs must not download PR artifacts")
assert((deployment_record_steps + deployment_status_steps + preview_comment_steps).none? { |step| run(step).match?(/docker |wrangler|npm /) }, "GitHub write jobs must not execute preview artifact, deploy, or package tooling")
assert(image_steps.none? { |step| env_hash(step).keys.any? { |key| key.start_with?("CLOUDFLARE_") } }, "preview image workflow must not expose Cloudflare secret env")
assert(image_steps.none? { |step| [ run(step), env_hash(step).values.join("\n") ].join("\n").match?(INLINE_SECRET_EXPRESSION) }, "preview image workflow must not reference GitHub secrets")

assert_run_includes(
  resolve_preview,
  "require('./trusted-preview-resolver/workers/preview/deploy/resolve_preview_request.cjs')",
  "resolvePreviewRequest({ github, context, core })"
)

[
  "workflowRun.pull_requests?.[0]",
  "github.rest.repos.listPullRequestsAssociatedWithCommit",
  "parsePreviewArtifactName",
  "pullRequest.head.sha !== headSha",
  "is stale for PR",
  "preview-cf",
  "filename.startsWith(\".github/workflows/\")",
  "preview-image-pr-${prNumber}-${headSha}",
  "!item.expired",
  "core.setOutput(\"artifact_name\", artifactName)",
  "core.setOutput(\"is_fork\", String(isFork))",
  "core.setOutput(\"should_deploy\", \"true\")"
].each { |needle| assert(resolver_script.include?(needle), "preview resolver must include #{needle.inspect}") }

prepare_run = assert_run_includes(prepare, *REQUIRED_PREPARE_LINES)
assert(!prepare_run.include?("npm install"), "prepare step must not use npm install")
assert(!prepare_run.include?("CLOUDFLARE_API_TOKEN"), "prepare step must not receive Cloudflare secrets")
assert(prepare_run.include?('preview_dir="$RUNNER_TEMP/sure-preview-worker"'), "trusted workspace must be created under RUNNER_TEMP")
assert(deploy_steps.select { |step| run(step).match?(/npm (ci|install)/) }.map { |step| step["name"] } == [ prepare["name"] ], "only prepare may install deploy tooling")

image_build_run = assert_run_includes(build_image, *REQUIRED_IMAGE_BUILD_LINES)
assert(image_build_run.include?("set -euo pipefail"), "preview image build must fail closed")
assert(!image_build_run.include?("CLOUDFLARE_"), "preview image build must not receive Cloudflare secrets")
assert(!image_build_run.include?('cat > "$manifest_file" <<JSON'), "preview image manifest must be generated with JSON escaping")

assert_run_includes(verify_checksum, 'expected_checksum="$(tr -d', 'actual_checksum="$(sha256sum "$image_archive"', "Preview image artifact checksum mismatch", "Preview image artifact contained unexpected files", "sure-preview-image.manifest.json", "Preview image manifest", "imageId is invalid")
assert_run_includes(load_image, 'gzip -dc "$image_archive" | docker load', 'docker image inspect "$expected_image"', "Loaded preview image ID did not match artifact manifest")
assert_run_includes(push_image, "./node_modules/.bin/wrangler containers push", "registry\\.cloudflare\\.com/", "image_ref=")
assert_run_includes(configure_image, "imageRef.startsWith('registry.cloudflare.com/')", 'const original = fs.readFileSync', 'const updated = original.replace(/image = "[^"]+"/', "updated === original", "Expected wrangler.toml to contain an image entry to rewrite", "JSON.stringify(imageRef)")
assert_run_includes(create_deployment, "github.rest.repos.createDeployment", "ref: headSha", "preview-pr-${prNumber}")
assert_run_includes(deploy, 'cd "$RUNNER_TEMP/sure-preview-worker"', "deploy_once()", "./node_modules/.bin/wrangler deploy --config wrangler.toml", '--var "PR_NUMBER:${PR_NUMBER}"', "associated with a different durable object namespace", 'if ! ./node_modules/.bin/wrangler delete --name "sure-preview-${PR_NUMBER}" --force', "Preview Worker delete failed", "retrying once")
assert_run_includes(warm_preview, "$PREVIEW_URL/_container_status", "--connect-timeout 5", "--max-time 15")
assert_run_includes(collect_diagnostics, "$PREVIEW_URL/_container_status", "--connect-timeout 5", "--max-time 15", "preview-diagnostics.json", "jq -e '.previewReady == true or .previewFailed == true'", "jq -e '.previewFailed == true'", "Preview diagnostics from _container_status reported previewFailed=true", "exit 1")
assert_run_includes(update_deployment_status, "github.rest.repos.createDeploymentStatus", "process.env.DEPLOY_RESULT === 'success'", "deployment_id: Number(process.env.DEPLOYMENT_ID)")
assert_run_includes(comment_on_pr, "github.rest.issues.listComments", "github.rest.issues.updateComment", "github.rest.issues.createComment", "Preview Deployment Ready")

secret_steps = deploy_steps.select { |step| env_hash(step).then { |env| env.key?("CLOUDFLARE_API_TOKEN") || env.key?("CLOUDFLARE_ACCOUNT_ID") } }
assert(secret_steps.map { |step| step["name"] } == [ push_image["name"], deploy["name"] ], "only image push and deploy may receive Cloudflare secrets")
assert_secret_env_sources!(push_image, EXPECTED_PUSH_SECRET_ENV)
assert_secret_env_sources!(deploy, EXPECTED_DEPLOY_SECRET_ENV)
secret_steps.each do |step|
  assert(step["working-directory"].nil?, "#{step["name"]} must not run from a PR-controlled working directory")
  assert(!run(step).match?(/npx wrangler|npm (ci|install)|docker build|docker save|docker run/), "#{step["name"]} must not execute PR-controlled build or package tooling with secrets")
end

puts "preview-deploy security check passed"
