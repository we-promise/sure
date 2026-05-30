#!/usr/bin/env ruby
# frozen_string_literal: true

%w[json pathname yaml].each { |library| require library }

ROOT = File.expand_path("..", __dir__)
PREVIEW_WORKFLOW_PATH = File.join(ROOT, ".github/workflows/preview-deploy.yml")
PR_WORKFLOW_PATH = File.join(ROOT, ".github/workflows/pr.yml")
LOCKFILE_PATH = File.join(ROOT, "workers/preview/package-lock.json")
PINNED_ACTION = /\A[^@\s]+@[a-f0-9]{40}\z/
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
EXPECTED_PREVIEW_PERMISSIONS = { "actions" => "read", "contents" => "read", "pull-requests" => "write", "deployments" => "write" }.freeze
EXPECTED_PR_IMAGE_PERMISSIONS = { "contents" => "read" }.freeze
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
REQUIRED_PR_IMAGE_LINES = [
  "docker build",
  "--platform linux/amd64",
  '--build-arg "BUILD_COMMIT_SHA=${HEAD_SHA}"',
  "-f Dockerfile.preview",
  '-t "${IMAGE_TAG}"',
  'docker save "${IMAGE_TAG}" | gzip -1 > "$RUNNER_TEMP/sure-preview-image.tar.gz"'
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
    assert(uses.start_with?("./") || uses.match?(PINNED_ACTION), "#{step["name"] || uses} must pin external actions") if uses
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

preview_on = workflow_on(preview_workflow)
pr_on = workflow_on(pr_workflow)
preview_job = preview_workflow.fetch("jobs").fetch("deploy-preview")
preview_steps = preview_job.fetch("steps")
preview_step_names = preview_steps.map { |step| step["name"] }
pr_image_job = pr_workflow.fetch("jobs").fetch("preview_image")
pr_image_steps = pr_image_job.fetch("steps")
wrangler = lockfile.fetch("packages").fetch("node_modules/wrangler")

wait_for_pr_ci = step!(preview_steps, "Wait for PR CI and preview image")
trusted_checkout = step!(preview_steps, "Checkout trusted preview tooling")
download_artifact = step!(preview_steps, "Download preview image artifact")
prepare = step!(preview_steps, "Prepare trusted preview deploy workspace")
load_image = step!(preview_steps, "Load preview image artifact")
push_image = step!(preview_steps, "Push preview image to Cloudflare registry")
configure_image = step!(preview_steps, "Configure trusted preview image reference")
deploy = step!(preview_steps, "Deploy to Cloudflare Containers")

pr_checkout = step!(pr_image_steps, "Checkout PR code")
build_image = step!(pr_image_steps, "Build preview image without secrets")
upload_image = step!(pr_image_steps, "Upload preview image artifact")

[
  [ "preview trigger", preview_on.keys, [ "pull_request_target" ] ],
  [ "preview trigger types", preview_on.dig("pull_request_target", "types"), %w[opened synchronize reopened labeled] ],
  [ "PR trigger types", pr_on.dig("pull_request", "types"), %w[opened synchronize reopened labeled] ],
  [ "PR workflow permissions", pr_workflow.fetch("permissions"), EXPECTED_PR_IMAGE_PERMISSIONS ],
  [ "preview job permissions", preview_job.fetch("permissions"), EXPECTED_PREVIEW_PERMISSIONS ],
  [ "preview job environment", environment_name(preview_job), "preview" ],
  [ "preview job timeout", preview_job.fetch("timeout-minutes"), 45 ],
  [ "preview concurrency group", preview_job.dig("concurrency", "group"), "preview-deploy-${{ github.event.pull_request.number }}" ],
  [ "preview concurrency cancellation", preview_job.dig("concurrency", "cancel-in-progress"), true ],
  [ "preview PR_NUMBER env", preview_job.dig("env", "PR_NUMBER"), "${{ github.event.pull_request.number }}" ],
  [ "preview HEAD_SHA env", preview_job.dig("env", "HEAD_SHA"), "${{ github.event.pull_request.head.sha }}" ],
  [ "trusted checkout ref", trusted_checkout.dig("with", "ref"), "${{ github.event.pull_request.base.sha }}" ],
  [ "trusted checkout path", trusted_checkout.dig("with", "path"), "trusted" ],
  [ "trusted checkout credentials", trusted_checkout.dig("with", "persist-credentials"), false ],
  [ "download artifact name", download_artifact.dig("with", "name"), "${{ steps.pr_ci.outputs.artifact_name }}" ],
  [ "download artifact run id", download_artifact.dig("with", "run-id"), "${{ steps.pr_ci.outputs.run_id }}" ],
  [ "download artifact path", download_artifact.dig("with", "path"), "${{ runner.temp }}/preview-image" ],
  [ "PR image permissions", pr_image_job.fetch("permissions"), EXPECTED_PR_IMAGE_PERMISSIONS ],
  [ "PR image timeout", pr_image_job.fetch("timeout-minutes"), 30 ],
  [ "PR checkout credentials", pr_checkout.dig("with", "persist-credentials"), false ],
  [ "PR image PR_NUMBER env", pr_image_job.dig("env", "PR_NUMBER"), "${{ github.event.pull_request.number }}" ],
  [ "PR image HEAD_SHA env", pr_image_job.dig("env", "HEAD_SHA"), "${{ github.event.pull_request.head.sha }}" ],
  [ "PR image tag env", pr_image_job.dig("env", "IMAGE_TAG"), "sure-preview-pr-${{ github.event.pull_request.number }}:${{ github.event.pull_request.head.sha }}" ],
  [ "upload artifact name", upload_image.dig("with", "name"), "preview-image-pr-${{ env.PR_NUMBER }}-${{ env.HEAD_SHA }}" ],
  [ "upload artifact retention", upload_image.dig("with", "retention-days"), 1 ],
  [ "Wrangler binary", wrangler.dig("bin", "wrangler"), "bin/wrangler.js" ]
].each { |label, actual, expected| assert(actual == expected, "#{label}: expected #{actual.inspect} to equal #{expected.inspect}") }

assert(preview_job.fetch("if").include?("preview-cf"), "privileged preview deploy must stay gated by preview-cf")
assert(pr_image_job.fetch("if").include?("preview-cf"), "PR image build must stay gated by preview-cf")
assert(lockfile.dig("packages", "", "devDependencies", "wrangler"), "Wrangler must stay a root dev dependency")
assert(lockfile.fetch("lockfileVersion") >= 3, "preview tooling lockfile must preserve npm ci integrity metadata")
assert(wrangler.fetch("resolved").start_with?("https://registry.npmjs.org/wrangler/-/wrangler-"), "Wrangler must resolve from npm registry")
assert(wrangler.fetch("integrity").start_with?("sha512-"), "Wrangler lockfile entry must keep npm integrity metadata")
assert(trusted_checkout.dig("with", "sparse-checkout").to_s.include?("workers/preview"), "trusted checkout must include preview tooling")
assert(preview_step_names.compact.uniq == preview_step_names.compact, "workflow step names must stay unique for security checks")
assert([ wait_for_pr_ci, trusted_checkout, download_artifact, prepare, load_image, push_image, configure_image, deploy ].map { |step| preview_steps.index(step) }.each_cons(2).all? { |left, right| left < right }, "preview workflow steps must preserve safe build-artifact deploy order")
assert(preview_steps.none? { |step| step["name"] == "Checkout PR code" }, "privileged preview workflow must not checkout PR code")
assert(preview_job.fetch("env").keys.none? { |name| name.start_with?("CLOUDFLARE_") }, "Cloudflare secrets must not be job-wide")

assert_pinned_actions!(preview_steps)
assert_pinned_actions!(pr_image_steps)
assert_no_inline_expressions!(preview_steps)
assert_no_inline_expressions!(pr_image_steps)

assert(preview_steps.none? { |step| normalized_working_directory(step["working-directory"]).match?(PR_CONTROLLED_WORKDIR) }, "privileged steps must not run from PR-controlled dirs")
assert(preview_steps.none? { |step| run(step).include?("npx wrangler") }, "privileged workflow must not use npx wrangler")
assert(preview_steps.none? { |step| run(step).match?(/Dockerfile\.preview|docker build|docker save/) }, "privileged workflow must not build PR Dockerfiles")
assert(preview_steps.none? { |step| run(step).include?("${GITHUB_WORKSPACE}/pr") || run(step).include?(" pr/") }, "privileged workflow must not reference PR checkout paths")

prepare_run = assert_run_includes(prepare, *REQUIRED_PREPARE_LINES)
assert(!prepare_run.include?("npm install"), "prepare step must not use npm install")
assert(!prepare_run.include?("CLOUDFLARE_API_TOKEN"), "prepare step must not receive Cloudflare secrets")
assert(prepare_run.include?('preview_dir="$RUNNER_TEMP/sure-preview-worker"'), "trusted workspace must be created under RUNNER_TEMP")
assert(preview_steps.select { |step| run(step).match?(/npm (ci|install)/) }.map { |step| step["name"] } == [ prepare["name"] ], "only prepare may install deploy tooling")

assert_run_includes(wait_for_pr_ci, "preview-image-pr-${prNumber}-${headSha}", "listWorkflowRunArtifacts", "core.setOutput('run_id'", "core.setOutput('artifact_name'")
assert_run_includes(wait_for_pr_ci, "const timeoutMs = 30 * 60 * 1000")
assert_run_includes(load_image, 'gzip -dc "$image_archive" | docker load', 'docker image inspect "$expected_image"')
assert_run_includes(push_image, "./node_modules/.bin/wrangler containers push", "registry\\.cloudflare\\.com/", "image_ref=")
assert_run_includes(configure_image, "imageRef.startsWith('registry.cloudflare.com/')", 'replace(/image = "[^"]+"/', "JSON.stringify(imageRef)")
assert_run_includes(deploy, 'cd "$RUNNER_TEMP/sure-preview-worker"', "./node_modules/.bin/wrangler deploy --config wrangler.toml", '--var "PR_NUMBER:${PR_NUMBER}"')

secret_steps = preview_steps.select { |step| step.fetch("env", {}).then { |env| env.key?("CLOUDFLARE_API_TOKEN") || env.key?("CLOUDFLARE_ACCOUNT_ID") } }
assert(secret_steps.map { |step| step["name"] } == [ push_image["name"], deploy["name"] ], "only image push and deploy may receive Cloudflare secrets")
assert_secret_env_sources!(push_image, EXPECTED_PUSH_SECRET_ENV)
assert_secret_env_sources!(deploy, EXPECTED_DEPLOY_SECRET_ENV)
secret_steps.each do |step|
  assert(step["working-directory"].nil?, "#{step["name"]} must not run from a PR-controlled working directory")
  assert(!run(step).match?(/npx wrangler|npm (ci|install)|docker build|docker save|docker run/), "#{step["name"]} must not execute PR-controlled build or package tooling with secrets")
end

pr_image_run = assert_run_includes(build_image, *REQUIRED_PR_IMAGE_LINES)
assert(pr_image_run.include?("set -euo pipefail"), "PR image build must fail closed")
assert(!pr_image_run.include?("CLOUDFLARE_"), "PR image build must not receive Cloudflare secrets")
assert(pr_image_steps.none? { |step| step.fetch("env", {}).keys.any? { |key| key.start_with?("CLOUDFLARE_") } }, "PR image workflow must not expose Cloudflare secret env")
assert(pr_image_steps.none? { |step| [ run(step), step.fetch("env", {}).values.join("\n") ].join("\n").match?(INLINE_SECRET_EXPRESSION) }, "PR image workflow must not reference GitHub secrets")

puts "preview-deploy security check passed"
