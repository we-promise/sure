const assert = require("node:assert/strict");
const { describe, it } = require("node:test");

const {
  parsePreviewArtifactName,
  resolvePreviewRequest,
  selectPullRequestNumber,
} = require("../../../workers/preview/deploy/resolve_preview_request.cjs");

function contextFor(workflowRun) {
  return {
    repo: {
      owner: "we-promise",
      repo: "sure",
    },
    payload: {
      workflow_run: workflowRun,
    },
  };
}

function previewArtifact(prNumber, headSha, extra = {}) {
  return {
    name: `preview-image-pr-${prNumber}-${headSha}`,
    expired: false,
    ...extra,
  };
}

function openPullRequest(number, headSha, fullName = "we-promise/sure", extra = {}) {
  return {
    number,
    state: "open",
    labels: [{ name: "preview-cf" }],
    head: {
      sha: headSha,
      repo: {
        full_name: fullName,
      },
    },
    base: {
      repo: {
        full_name: "we-promise/sure",
      },
    },
    ...extra,
  };
}

function fakeGithub({ artifacts = [], associatedPullRequests = [], pullRequest, files = [] }) {
  return {
    paginate: async (endpoint, params) => {
      if (endpoint.endpointName === "listWorkflowRunArtifacts") {
        assert.equal(params.run_id, 123);
        return artifacts;
      }

      if (endpoint.endpointName === "listFiles") {
        return files;
      }

      throw new Error(`unexpected paginate endpoint ${endpoint.endpointName}`);
    },
    rest: {
      actions: {
        listWorkflowRunArtifacts: { endpointName: "listWorkflowRunArtifacts" },
      },
      pulls: {
        get: async ({ pull_number }) => {
          assert.equal(pull_number, pullRequest.number);
          return { data: pullRequest };
        },
        listFiles: { endpointName: "listFiles" },
      },
      repos: {
        listPullRequestsAssociatedWithCommit: async () => ({ data: associatedPullRequests }),
      },
    },
  };
}

function fakeCore() {
  const outputs = {};
  const messages = [];
  let failure = null;

  return {
    core: {
      info: (message) => messages.push(message),
      setFailed: (message) => {
        failure = message;
      },
      setOutput: (name, value) => {
        outputs[name] = value;
      },
    },
    get failure() {
      return failure;
    },
    messages,
    outputs,
  };
}

describe("parsePreviewArtifactName", () => {
  it("parses preview image artifact names", () => {
    const parsed = parsePreviewArtifactName("preview-image-pr-2017-4f1159e99c7785bc370f53510284c251fabdb75b");

    assert.deepEqual(parsed, {
      prNumber: 2017,
      headSha: "4f1159e99c7785bc370f53510284c251fabdb75b",
    });
  });

  it("rejects malformed names", () => {
    assert.equal(parsePreviewArtifactName("preview-image-pr-0-4f1159e99c7785bc370f53510284c251fabdb75b"), null);
    assert.equal(parsePreviewArtifactName("preview-image-pr-2017-notasha"), null);
    assert.equal(parsePreviewArtifactName("other-artifact"), null);
  });
});

describe("selectPullRequestNumber", () => {
  const headSha = "4f1159e99c7785bc370f53510284c251fabdb75b";
  const context = contextFor({ id: 123, head_sha: headSha });

  it("prefers the preview artifact when commit association matches", () => {
    const selected = selectPullRequestNumber({
      runPullRequest: undefined,
      artifacts: [previewArtifact(2017, headSha)],
      associatedPullRequests: [openPullRequest(2017, headSha, "Rene0422/sure")],
      context,
      headSha,
    });

    assert.deepEqual(selected, {
      prNumber: 2017,
      source: "artifact_name+commit_association",
    });
  });

  it("records workflow_run as a corroborating source when it matches the preview artifact", () => {
    const selected = selectPullRequestNumber({
      runPullRequest: { number: 2017 },
      artifacts: [previewArtifact(2017, headSha)],
      associatedPullRequests: [],
      context,
      headSha,
    });

    assert.deepEqual(selected, {
      prNumber: 2017,
      source: "artifact_name+workflow_run",
    });
  });

  it("records workflow_run and commit association when both match the preview artifact", () => {
    const selected = selectPullRequestNumber({
      runPullRequest: { number: 2017 },
      artifacts: [previewArtifact(2017, headSha)],
      associatedPullRequests: [openPullRequest(2017, headSha, "Rene0422/sure")],
      context,
      headSha,
    });

    assert.deepEqual(selected, {
      prNumber: 2017,
      source: "artifact_name+workflow_run+commit_association",
    });
  });

  it("uses a matching artifact when the same head SHA is associated with more than one PR", () => {
    const selected = selectPullRequestNumber({
      runPullRequest: undefined,
      artifacts: [previewArtifact(2060, headSha)],
      associatedPullRequests: [
        openPullRequest(2059, headSha),
        openPullRequest(2060, headSha),
      ],
      context,
      headSha,
    });

    assert.deepEqual(selected, {
      prNumber: 2060,
      source: "artifact_name+commit_association",
    });
  });

  it("fails closed when workflow metadata disagrees with the preview artifact", () => {
    const selected = selectPullRequestNumber({
      runPullRequest: { number: 1985 },
      artifacts: [previewArtifact(1798, headSha)],
      associatedPullRequests: [openPullRequest(1798, headSha)],
      context,
      headSha,
    });

    assert.equal(selected.prNumber, undefined);
    assert.equal(typeof selected.error, "string");
    assert.match(selected.error, /conflicts with workflow_run PR 1985/);
  });

  it("fails closed when commit association disagrees with the preview artifact", () => {
    const selected = selectPullRequestNumber({
      runPullRequest: undefined,
      artifacts: [previewArtifact(1798, headSha)],
      associatedPullRequests: [openPullRequest(1985, headSha)],
      context,
      headSha,
    });

    assert.equal(selected.prNumber, undefined);
    assert.equal(typeof selected.error, "string");
    assert.match(selected.error, /conflicts with commit-associated PRs 1985/);
  });

  it("refuses ambiguous associated PRs without a single matching artifact", () => {
    const selected = selectPullRequestNumber({
      runPullRequest: undefined,
      artifacts: [],
      associatedPullRequests: [
        openPullRequest(2059, headSha),
        openPullRequest(2060, headSha),
      ],
      context,
      headSha,
    });

    assert.match(selected.error, /multiple open pull requests/);
  });
});

describe("resolvePreviewRequest", () => {
  const headSha = "4f1159e99c7785bc370f53510284c251fabdb75b";
  const workflowRun = {
    id: 123,
    head_sha: headSha,
    pull_requests: [],
  };

  it("resolves fork PRs from commit association and marks deployment creation as skippable", async () => {
    const pullRequest = openPullRequest(2017, headSha, "Rene0422/sure");
    const state = fakeCore();
    const github = fakeGithub({
      artifacts: [previewArtifact(2017, headSha)],
      associatedPullRequests: [pullRequest],
      pullRequest,
    });

    await resolvePreviewRequest({ github, context: contextFor(workflowRun), core: state.core });

    assert.equal(state.failure, null);
    assert.equal(state.outputs.should_deploy, "true");
    assert.equal(state.outputs.pr_number, "2017");
    assert.equal(state.outputs.head_sha, headSha);
    assert.equal(state.outputs.artifact_name, `preview-image-pr-2017-${headSha}`);
    assert.equal(state.outputs.is_fork, "true");
    assert.equal(state.outputs.resolution_source, "artifact_name+commit_association");
  });

  it("resolves PRs from artifact names when workflow and commit association metadata are unavailable", async () => {
    const pullRequest = openPullRequest(2017, headSha, "Rene0422/sure");
    const state = fakeCore();
    const github = fakeGithub({
      artifacts: [previewArtifact(2017, headSha)],
      associatedPullRequests: [],
      pullRequest,
    });

    await resolvePreviewRequest({ github, context: contextFor(workflowRun), core: state.core });

    assert.equal(state.failure, null);
    assert.equal(state.outputs.should_deploy, "true");
    assert.equal(state.outputs.pr_number, "2017");
    assert.equal(state.outputs.head_sha, headSha);
    assert.equal(state.outputs.artifact_name, `preview-image-pr-2017-${headSha}`);
    assert.equal(state.outputs.is_fork, "true");
    assert.equal(state.outputs.resolution_source, "artifact_name");
    assert.match(state.messages.join("\n"), /Resolved PR 2017 from artifact_name; fork=true/);
  });

  it("treats stale workflow runs as successful no-ops", async () => {
    const currentHeadSha = "c79a325513160e651680170f817d802395c38d86";
    const pullRequest = openPullRequest(2060, currentHeadSha);
    const state = fakeCore();
    const github = fakeGithub({
      artifacts: [previewArtifact(2060, headSha)],
      associatedPullRequests: [openPullRequest(2060, headSha)],
      pullRequest,
    });

    await resolvePreviewRequest({ github, context: contextFor(workflowRun), core: state.core });

    assert.equal(state.failure, null);
    assert.equal(state.outputs.should_deploy, "false");
    assert.match(state.messages.join("\n"), /is stale for PR 2060/);
  });

  it("fails closed when a labeled PR changed workflow files", async () => {
    const pullRequest = openPullRequest(2060, headSha);
    const state = fakeCore();
    const github = fakeGithub({
      artifacts: [previewArtifact(2060, headSha)],
      associatedPullRequests: [pullRequest],
      pullRequest,
      files: [{ filename: ".github/workflows/pr.yml" }],
    });

    await resolvePreviewRequest({ github, context: contextFor(workflowRun), core: state.core });

    assert.match(state.failure, /base-trusted workflow definitions/);
    assert.equal(state.outputs.should_deploy, "false");
  });

  it("fails closed when the expected artifact is missing", async () => {
    const pullRequest = openPullRequest(2060, headSha);
    const state = fakeCore();
    const github = fakeGithub({
      artifacts: [],
      associatedPullRequests: [pullRequest],
      pullRequest,
    });

    await resolvePreviewRequest({ github, context: contextFor(workflowRun), core: state.core });

    assert.match(state.failure, /did not publish preview-image-pr-2060-/);
    assert.equal(state.outputs.should_deploy, "false");
  });

  it("skips PRs without the preview label before requiring an artifact", async () => {
    const pullRequest = openPullRequest(2060, headSha, "we-promise/sure", { labels: [] });
    const state = fakeCore();
    const github = fakeGithub({
      artifacts: [],
      associatedPullRequests: [pullRequest],
      pullRequest,
    });

    await resolvePreviewRequest({ github, context: contextFor(workflowRun), core: state.core });

    assert.equal(state.failure, null);
    assert.equal(state.outputs.should_deploy, "false");
    assert.match(state.messages.join("\n"), /does not have the preview-cf label/);
  });
});
