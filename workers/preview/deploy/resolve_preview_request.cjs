const PREVIEW_ARTIFACT_PATTERN = /^preview-image-pr-([1-9][0-9]*)-([a-f0-9]{40})$/;

function parsePreviewArtifactName(name) {
  const match = PREVIEW_ARTIFACT_PATTERN.exec(name);
  if (!match) return null;

  return {
    prNumber: Number(match[1]),
    headSha: match[2],
  };
}

function repoFullName(context) {
  return `${context.repo.owner}/${context.repo.repo}`;
}

function labelsIncludePreview(pullRequest) {
  return pullRequest.labels.some((label) => label.name === "preview-cf");
}

function artifactCandidates(artifacts, headSha) {
  return artifacts
    .filter((artifact) => !artifact.expired)
    .map((artifact) => ({
      artifact,
      parsed: parsePreviewArtifactName(artifact.name),
    }))
    .filter((candidate) => candidate.parsed?.headSha === headSha);
}

function uniqueNumbers(candidates) {
  return [...new Set(candidates.map((candidate) => candidate.parsed.prNumber))];
}

function uniquePullRequestNumbers(pullRequests) {
  return [...new Set(pullRequests.map((pullRequest) => pullRequest.number))];
}

function associatedPullRequestsForHead(associatedPullRequests, context, headSha) {
  const baseRepo = repoFullName(context);

  return associatedPullRequests.filter((pullRequest) => (
    pullRequest.state === "open" &&
    pullRequest.head?.sha === headSha &&
    pullRequest.base?.repo?.full_name === baseRepo
  ));
}

function selectPullRequestNumber({ runPullRequest, artifacts, associatedPullRequests, context, headSha }) {
  const associatedHeadPullRequests = associatedPullRequestsForHead(associatedPullRequests, context, headSha);
  const associatedPullRequestNumbers = uniquePullRequestNumbers(associatedHeadPullRequests);
  const artifactPullRequestNumbers = uniqueNumbers(artifactCandidates(artifacts, headSha));
  const workflowRunPullRequestNumber = runPullRequest?.number ?? null;

  if (artifactPullRequestNumbers.length > 1) {
    return {
      error: `Workflow run ${headSha} published preview artifacts for multiple pull requests`,
    };
  }

  if (artifactPullRequestNumbers.length === 1) {
    const artifactPullRequestNumber = artifactPullRequestNumbers[0];

    if (workflowRunPullRequestNumber && workflowRunPullRequestNumber !== artifactPullRequestNumber) {
      return {
        error: `Preview artifact PR ${artifactPullRequestNumber} conflicts with workflow_run PR ${workflowRunPullRequestNumber}`,
      };
    }

    if (
      associatedPullRequestNumbers.length > 0 &&
      !associatedPullRequestNumbers.includes(artifactPullRequestNumber)
    ) {
      return {
        error: `Preview artifact PR ${artifactPullRequestNumber} conflicts with commit-associated PRs ${associatedPullRequestNumbers.join(", ")}`,
      };
    }

    const corroboratingSources = [];
    if (workflowRunPullRequestNumber === artifactPullRequestNumber) corroboratingSources.push("workflow_run");
    if (associatedPullRequestNumbers.includes(artifactPullRequestNumber)) {
      corroboratingSources.push("commit_association");
    }

    return {
      prNumber: artifactPullRequestNumber,
      source:
        corroboratingSources.length > 0
          ? `artifact_name+${corroboratingSources.join("+")}`
          : "artifact_name",
    };
  }

  if (workflowRunPullRequestNumber) {
    if (
      associatedPullRequestNumbers.length > 0 &&
      !associatedPullRequestNumbers.includes(workflowRunPullRequestNumber)
    ) {
      return {
        error: `workflow_run PR ${workflowRunPullRequestNumber} conflicts with commit-associated PRs ${associatedPullRequestNumbers.join(", ")}`,
      };
    }

    return {
      prNumber: workflowRunPullRequestNumber,
      source: "workflow_run",
    };
  }

  if (associatedHeadPullRequests.length === 1) {
    return {
      prNumber: associatedHeadPullRequests[0].number,
      source: "commit_association",
    };
  }

  if (associatedHeadPullRequests.length > 1) {
    return {
      error: `Workflow run head SHA ${headSha} is associated with multiple open pull requests and no single preview artifact matched`,
    };
  }

  return {
    prNumber: null,
    source: "none",
  };
}

async function resolvePreviewRequest({ github, context, core }) {
  const workflowRun = context.payload.workflow_run;
  const runPullRequest = workflowRun.pull_requests?.[0];
  const headSha = workflowRun.head_sha;

  core.setOutput("should_deploy", "false");

  const artifacts = await github.paginate(github.rest.actions.listWorkflowRunArtifacts, {
    owner: context.repo.owner,
    repo: context.repo.repo,
    run_id: workflowRun.id,
    per_page: 100,
  });

  const { data: associatedPullRequests } = await github.rest.repos.listPullRequestsAssociatedWithCommit({
    owner: context.repo.owner,
    repo: context.repo.repo,
    commit_sha: headSha,
  });

  const selected = selectPullRequestNumber({
    runPullRequest,
    artifacts,
    associatedPullRequests,
    context,
    headSha,
  });

  if (selected.error) {
    core.setFailed(selected.error);
    return;
  }

  if (!selected.prNumber) {
    core.info("Workflow run is not associated with an open pull request");
    return;
  }

  const prNumber = selected.prNumber;
  const { data: pullRequest } = await github.rest.pulls.get({
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number: prNumber,
  });

  if (pullRequest.state !== "open") {
    core.info(`PR ${prNumber} is ${pullRequest.state}; skipping preview deploy`);
    return;
  }

  if (pullRequest.head.sha !== headSha) {
    core.info(`Workflow run head SHA ${headSha} is stale for PR ${prNumber}; current head is ${pullRequest.head.sha}`);
    return;
  }

  const hasPreviewLabel = labelsIncludePreview(pullRequest);
  if (!hasPreviewLabel) {
    core.info(`PR ${prNumber} does not have the preview-cf label`);
    return;
  }

  const files = await github.paginate(github.rest.pulls.listFiles, {
    owner: context.repo.owner,
    repo: context.repo.repo,
    pull_number: prNumber,
    per_page: 100,
  });
  const workflowChanges = files
    .map((file) => file.filename)
    .filter((filename) => filename.startsWith(".github/workflows/"));

  if (workflowChanges.length > 0) {
    core.setFailed(`Preview deployment requires base-trusted workflow definitions; changed workflow files: ${workflowChanges.join(", ")}`);
    return;
  }

  const artifactName = `preview-image-pr-${prNumber}-${headSha}`;
  const artifact = artifacts.find((item) => item.name === artifactName && !item.expired);

  if (!artifact) {
    core.setFailed(`Pull Request workflow run ${workflowRun.id} did not publish ${artifactName}`);
    return;
  }

  const isFork = pullRequest.head.repo?.full_name !== repoFullName(context);
  core.info(`Resolved PR ${prNumber} from ${selected.source}; fork=${isFork}`);

  core.setOutput("artifact_name", artifactName);
  core.setOutput("head_sha", headSha);
  core.setOutput("is_fork", String(isFork));
  core.setOutput("pr_number", String(prNumber));
  core.setOutput("resolution_source", selected.source);
  core.setOutput("should_deploy", "true");
}

module.exports = {
  artifactCandidates,
  associatedPullRequestsForHead,
  parsePreviewArtifactName,
  resolvePreviewRequest,
  selectPullRequestNumber,
};
