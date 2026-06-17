import fs from "node:fs";

const token = process.env.GITHUB_TOKEN;
const teamTokenMap = process.env.TEAM_TOKEN_MAP ?? "";
const org = process.env.TEAM_LOOKUP_ORG;
const username = process.env.COMMENT_AUTHOR;
const repository = process.env.GITHUB_REPOSITORY;
const prNumber = process.env.PR_NUMBER;
const outputPath = process.env.GITHUB_OUTPUT;

function parseMap(value) {
  return value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const separator = line.indexOf("=");
      if (separator === -1) {
        throw new Error(`Invalid team_token_map line: ${line}`);
      }

      return {
        team: line.slice(0, separator).trim(),
        apiKey: line.slice(separator + 1).trim(),
      };
    });
}

async function github(path, options = {}) {
  return fetch(`https://api.github.com${path}`, {
    ...options,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "X-GitHub-Api-Version": "2022-11-28",
      ...(options.headers ?? {}),
    },
  });
}

async function postComment(body) {
  if (!repository || !prNumber) {
    console.error(body);
    return;
  }

  const [owner, repo] = repository.split("/");
  await github(`/repos/${owner}/${repo}/issues/${prNumber}/comments`, {
    method: "POST",
    body: JSON.stringify({ body }),
  });
}

async function fail(body) {
  console.error(body);
  await postComment(body);
  process.exit(1);
}

async function isTeamMember(team) {
  const response = await github(`/orgs/${org}/teams/${team}/memberships/${username}`);

  if (response.status === 200) {
    return true;
  }
  if (response.status === 404) {
    return false;
  }
  if (response.status === 403) {
    await fail(
      `**OpenCode review failed:** cannot read team membership for org \`${org}\`. Configure \`team_lookup_token\` with permission to read org team membership.`
    );
  }

  const text = await response.text();
  throw new Error(`Team lookup failed for ${team}: HTTP ${response.status} ${text}`);
}

function validateInput(entries) {
  if (!token) {
    return "**OpenCode review failed:** missing GitHub token for team lookup.";
  }
  if (!org) {
    return "**OpenCode review failed:** missing team lookup org.";
  }
  if (!username) {
    return "**OpenCode review failed:** missing PR comment author.";
  }
  if (!outputPath) {
    return "**OpenCode review failed:** missing GitHub output path.";
  }
  if (entries.length === 0) {
    return "**OpenCode review failed:** `team_token_map` is empty.";
  }

  const invalid = entries.find((entry) => !entry.team || !entry.apiKey);
  if (invalid) {
    return "**OpenCode review failed:** every `team_token_map` line must be `team_slug=secret_value`.";
  }

  return "";
}

let entries;
try {
  entries = parseMap(teamTokenMap);
} catch (error) {
  await fail(`**OpenCode review failed:** ${error.message}`);
}

const validationError = validateInput(entries);
if (validationError) {
  await fail(validationError);
}

const entry = entries[0];
fs.appendFileSync(outputPath, `selected_team=${entry.team}\n`);
fs.appendFileSync(outputPath, `opencode_api_key=${entry.apiKey}\n`);
process.exit(0);
