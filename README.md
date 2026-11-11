# qse-scanner — Quantum Safe Explorer for GitHub Actions

A container image plus a reusable GitHub workflow. Together they run IBM's **Quantum Safe Explorer (QSE)** cryptographic scanner on a repository as part of its own CI, and can optionally upload the findings to **Guardium Cryptography Manager (GCM)**.

[QSE Pod GitHub repository](https://github.com/ncee-dp-tech-sme/qse_pod)

## Table of Contents

1. [How it works](#how-it-works)
2. [Using it from another repository](#using-it-from-another-repository)
3. [Workflow inputs](#workflow-inputs)
4. [One-time setup (maintainers)](#one-time-setup-maintainers)
5. [Building and releasing the image](#building-and-releasing-the-image)
6. [Running locally with Docker](#running-locally-with-docker)
7. [Language detection and pre-compilation](#language-detection-and-pre-compilation)
8. [QSE flag reference and rationale](#qse-flag-reference-and-rationale)
9. [GCM API reference](#gcm-api-reference)
10. [Security design](#security-design)
11. [Troubleshooting](#troubleshooting)

---

## How it works

```
 Calling repo workflow                    ncee-dp-tech-sme/qse_pod
 ─────────────────────                    ───────────────────────────────────────
 jobs.qse.uses: …/qse-scan.yml@v1  ──▶   .github/workflows/qse-scan.yml
                                          job container: ghcr.io/ncee-dp-tech-sme/qse-scanner:v1
                                            1. actions/checkout (caller's code)
                                            2. optional pre_build_command
                                            3. qse-scan
                                               ├─ detect languages + pre-compile
                                               ├─ /opt/qse/cli.sh (QSE scan)
                                               ├─ check for weak algorithms
                                               └─ upload findings to GCM (optional)
                                            4. upload results as a workflow artifact
```

| Path | Purpose |
|---|---|
| `Dockerfile` | Image with the QSE CLI plus toolchains for every QSE language |
| `scripts/qse-scan.sh` | Scan entrypoint (`/usr/local/bin/qse-scan` in the image) |
| `.github/workflows/build-image.yml` | Builds the image, smoke-tests it, and pushes it to GHCR |
| `.github/workflows/qse-scan.yml` | Reusable workflow that other repos call |
| `examples/caller-workflow.yml` | Copy-paste caller workflow |
| `tests/fixtures/` | Small Java/Python projects with weak crypto, used by the smoke test |

---

## Using it from another repository

Add `.github/workflows/qse-scan.yml` to the repo you want to scan (full example: [examples/caller-workflow.yml](examples/caller-workflow.yml)):

```yaml
name: Quantum Safe scan
on:
  push:
    branches: [main]
  pull_request:

jobs:
  qse:
    permissions:
      contents: read
      packages: read          # needed to pull the private scanner image
    uses: ncee-dp-tech-sme/qse_pod/.github/workflows/qse-scan.yml@v1
    with:
      gcm_server_url: ${{ vars.GCM_SERVER_URL }}
    secrets:
      gcm_bearer_token: ${{ secrets.GCM_BEARER_TOKEN }}
```

Results are attached to the run as the `qse-scan-results` artifact, and a summary table is added to the job summary. If `gcm_server_url` and `gcm_bearer_token` are both set, the findings are also uploaded to GCM.

The job fails on weak algorithms only when you ask it to (`fail_on_critical: true`). It also exposes a `critical_found` output, so later jobs can decide what to do:

```yaml
  gate:
    needs: qse
    if: needs.qse.outputs.critical_found == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo "::warning::Weak cryptography detected"
```

### Projects with a custom build

The built-in pre-compile step (see [below](#language-detection-and-pre-compilation)) covers standard Maven, Gradle, Go, CMake/Make, .NET and Dart layouts. If your project needs something else (private Maven repositories, a wrapper script, generated code), run it yourself and skip the built-in step:

```yaml
    with:
      pre_build_command: ./mvnw -B -DskipTests package dependency:copy-dependencies
      skip_build: true
```

`pre_build_command` runs inside the scanner container, so every toolchain in the image is available to it.

---

## Workflow inputs

| Input | Default | Description |
|---|---|---|
| `image_tag` | `v1` | Scanner image tag |
| `runs_on` | `ubuntu-latest` | Runner label (needs Linux + Docker) |
| `working_directory` | `.` | Sub-directory to scan |
| `app_name` | repo name | Application label in QSE/GCM |
| `app_version` | short commit SHA | Version label |
| `languages` | auto-detect | Comma-separated override, e.g. `.java,.py` |
| `scan_all_languages` | `false` | Scan every QSE language regardless of detection |
| `exclude_paths` | `src/test,vendor,node_modules,.git,venv,.venv,.qse-venv` | Passed to `-ef` |
| `py_module_path` | auto venv | Passed to `-py_module_path` |
| `skip_build` | `false` | Skip the built-in pre-compile step |
| `pre_build_command` | — | Bash command run before the scan |
| `cache_dependencies` | `true` | Cache `~/.m2`, `~/.gradle`, `~/.nuget` |
| `upload_to_gcm` | `auto` | `auto` uploads when URL + token are set; `true` makes missing config an error; `false` never uploads |
| `gcm_server_url` | — | GCM base URL |
| `fail_on_critical` | `false` | Fail when MD5 / SHA-1 / DES / 3DES / RC4 / RSA-1024 appear in the results |
| `artifact_name` | `qse-scan-results` | Artifact name |

| Secret | Description |
|---|---|
| `gcm_bearer_token` | GCM API bearer token (optional) |

| Output | Description |
|---|---|
| `critical_found` | `'true'` if weak algorithms were found |

---

## One-time setup (maintainers)

The image contains the private IBM QSE CLI, so **the image and the workflow stay private to the organisation**.

1. **Build secret.** In this repo, add the secret `QSE_TOKEN`: a github.ibm.com token with read access to the QSE CLI repository. If the CLI lives somewhere other than the default URL, also set the repository variable `QSE_REPO_URL`.
2. **Run the build.** Run *Build qse-scanner image* (`workflow_dispatch`) or push to `main`. This publishes `ghcr.io/ncee-dp-tech-sme/qse-scanner`.
3. **Package access.** On GitHub, open the package → *Package settings* → *Manage Actions access* and add every repository that will run scans, with the **Read** role. Alternatively, set the package visibility to **Internal**. Without this step, callers fail at "Initialize containers" with `denied`.
4. **Workflow access.** In this repo, go to *Settings → Actions → General → Access* and choose **"Accessible from repositories in the 'ncee-dp-tech-sme' organization"**. Without it, callers get `workflow was not found`.
5. **Caller config.** Each calling repo (or the org) gets the secret `GCM_BEARER_TOKEN` and the variable `GCM_SERVER_URL`. These are only needed if you upload to GCM.

> **Network requirement:** the build clones the QSE CLI from `github.ibm.com`. If GitHub-hosted runners can't reach it, build and push from a machine that can (see the next section). Alternatively, set `runs-on` in `build-image.yml` to a self-hosted runner.

---

## Building and releasing the image

The QSE token is passed as a **BuildKit secret**, so it never ends up in an image layer or in the build history.

```bash
export QSE_TOKEN=<github.ibm.com token>
docker buildx build \
  --secret id=qse_token,env=QSE_TOKEN \
  --build-arg QSE_REPO_URL=https://github.ibm.com/quantum-safe-engineering/quantum-safe-read-repos.git \
  -t ghcr.io/ncee-dp-tech-sme/qse-scanner:dev .

# Manual push (if CI can't reach github.ibm.com)
echo "$GHCR_PAT" | docker login ghcr.io -u <user> --password-stdin   # PAT with write:packages
docker push ghcr.io/ncee-dp-tech-sme/qse-scanner:dev
```

| Build arg | Default |
|---|---|
| `QSE_REPO_URL` | IBM quantum-safe-read-repos URL |
| `QSE_REPO_REF` | default branch (set a tag/branch to pin the CLI version) |
| `GO_VERSION` / `MAVEN_VERSION` / `GRADLE_VERSION` / `DART_VERSION` | pinned in the Dockerfile |

The image is roughly 3–4 GB, because it includes the JDK, .NET SDK, Go, Dart, GCC and the Python headers.

### Releasing

`build-image.yml` tags images on these events:

| Event | Image tags |
|---|---|
| push to `main` | `main`, `sha-<short>` |
| git tag `v1.2.3` | `v1.2.3`, `v1.2`, `v1`, `sha-<short>` |
| pull request | built and smoke-tested, not pushed |

Callers use `qse-scan.yml@v1` with `image_tag: v1` (the default). To release:

```bash
git tag v1.2.3 && git push origin v1.2.3     # publishes image tags v1.2.3, v1.2, v1
git tag -f v1 && git push -f origin v1       # move the workflow ref callers use
```

For a breaking change, release `v2.x.y` and change the `image_tag` default in `qse-scan.yml` to `v2` on that line.

---

## Running locally with Docker

```bash
docker run --rm \
  -v "$PWD:/src" -v "$PWD/../qse-results:/out" \
  -e SCAN_DIR=/src -e OUTPUT_DIR=/out \
  -e UPLOAD_TO_GCM=false \
  ghcr.io/ncee-dp-tech-sme/qse-scanner:v1
```

`qse-scan` is configured entirely through environment variables. Run `docker run --rm ghcr.io/ncee-dp-tech-sme/qse-scanner:v1 --help` to list them all. Inside GitHub Actions they default from `GITHUB_WORKSPACE`, `GITHUB_REPOSITORY`, `GITHUB_SHA` and `RUNNER_TEMP`.

| Exit code | Meaning |
|---|---|
| `0` | Scan (and upload, if enabled) succeeded |
| `1` | Scan failed, GCM upload failed, or the configuration is invalid |
| `2` | Critical findings and `FAIL_ON_CRITICAL=true` |

Note: pre-compilation writes build output (`target/`, `build/`, `.qse-venv/`) into the scanned directory.

---

## Language detection and pre-compilation

QSE gives better results for compiled languages when build output is available. `qse-scan` detects languages from files in the tree (skipping `.git`, virtualenvs, `node_modules` and `vendor`) and runs one build step per language. Build failures are warnings: the scan still runs on the source.

| Language | Detection files | Pre-compile step |
|---|---|---|
| Java | `*.java`, `pom.xml`, `build.gradle(.kts)` | `mvn clean install dependency:copy-dependencies -DskipTests` / `./gradlew` or `gradle build -x test` / `javac` |
| Go | `*.go`, `go.mod` | `go build ./...` |
| Python | `*.py`, `requirements.txt`, `pyproject.toml`, `setup.py` | `pip install` into `<repo>/.qse-venv` |
| C/C++ | `*.cpp`, `*.cc`, `*.cxx`, `CMakeLists.txt`, `Makefile` | `cmake` + build / `make` |
| C# | `*.cs`, `*.csproj`, `*.sln` | `dotnet build -c Release` |
| Dart | `*.dart`, `pubspec.yaml` | `dart pub get` |

If nothing is detected, all languages are scanned. JavaScript/TypeScript isn't in QSE's language list (`-l {.go,.dart,.java,.py,.cpp,.cs}`), so Node is not included in the image.

### Python dependency handling

- **Option 1 (default):** when `requirements.txt`, `pyproject.toml` or `setup.py` exists, dependencies are installed into `<repo>/.qse-venv`. That venv's `site-packages` is passed to QSE as `-py_module_path`, and the venv itself is excluded from the scan.
- **Option 2:** set `py_module_path` (or `PY_MODULE_PATH`) to point at pre-installed modules. This takes precedence over the venv.

---

## QSE flag reference and rationale

| Flag | Value used | Language(s) | Rationale |
|---|---|---|---|
| `-i` | `SCAN_DIR` | All | Root of the checked-out repository |
| `-l` | detected extensions | All | Scoped to the languages present, to avoid noise |
| `-o` | `OUTPUT_DIR` | All | Outside the scanned tree (`$RUNNER_TEMP/qse-results`), so results aren't scanned again |
| `-app` | `APP_NAME` | All | Application label in GCM |
| `-app_ver` | `APP_VERSION` / short SHA | All | Ties results to a specific commit |
| `-log` | — | All | Detailed logs; the CI log is the only diagnostic channel |
| `-ef` | `EXCLUDE_PATHS` | All | Excludes tests, vendored code and virtualenvs |
| `-da` | — | Python, Java | Usage Analysis. Always on for Python; on for Java when compiled classes exist. Passed once |
| `-py_module_path` | `PY_MODULE_PATH` or venv site-packages | Python | Lets QSE resolve third-party imports |
| `-cf` | `target/classes;target/dependency` / `build/classes;build/libs` | Java | Bytecode-level analysis of classes and dependency JARs |
| `-em` | `true` | Dart | Exact package-name matching to reduce false positives |

### Flags intentionally not used

| Flag | Reason |
|---|---|
| `-ccdir` | The default Dart class-catalog resource is sufficient |
| `-nmo` | Name-matching-only reduces scan depth |
| `-pf` / `-sf` | Repo-specific filters; `-ef` covers the common cases |
| `-config` | Configuration comes from environment variables / workflow inputs |

---

## GCM API reference

| Findings file | Endpoint |
|---|---|
| `quantum_safe_api_discovery_findings.json` | `POST {GCM_SERVER_URL}/ibm/pv/api/v1/upload-qse-findings/discovery?repositoryUrl=<encoded>` |
| `quantum_safe_cryptography_analysis_findings_*.json` | `POST {GCM_SERVER_URL}/ibm/pv/api/v1/upload-qse-findings/analytics?repositoryUrl=<encoded>` |

`repositoryUrl` defaults to `https://github.com/<owner>/<repo>`, URL-encoded.

Each request:

```
Authorization: Bearer <GCM_BEARER_TOKEN>
token_type: api_key
Content-Type: multipart/form-data   (file=@<findings>.json;type=application/json)
```

Example:

```bash
curl -X POST \
  '{GCM_SERVER_URL}/ibm/pv/api/v1/upload-qse-findings/discovery?repositoryUrl=https%3A%2F%2Fgithub.com%2Forg%2Frepo' \
  -H 'accept: application/json' \
  -H 'Authorization: Bearer <GCM_BEARER_TOKEN>' \
  -H 'token_type: api_key' \
  -F 'file=@quantum_safe_api_discovery_findings.json;type=application/json'
```

HTTP 5xx and network errors are retried 3 times with exponential backoff (5 s, 10 s, 20 s). HTTP 4xx fails immediately. An upload failure fails the job.

---

## Security design

- **QSE token is a BuildKit secret.** It is mounted only during the clone step and never written to a layer, an `ARG` or the build history.
- **The image is private.** GHCR access is granted per repository; callers pull with their own `GITHUB_TOKEN` (`packages: read`).
- **The GCM token is never logged.** It is passed as a workflow secret (masked by Actions) and used only in a `curl -H` argument.
- **Checkout without persisted credentials.** `persist-credentials: false`, so the scanned code and build steps can't read the caller's `GITHUB_TOKEN` from git config.
- **Least privilege.** The scan job requests only `contents: read` and `packages: read`.
- **Runs as root inside the job container.** GitHub Actions requires this so that `actions/checkout` can write to the mounted workspace. The container is ephemeral and discarded after the job.
- **Untrusted pull requests.** The pre-compile step runs the repo's own build scripts (Maven plugins, Makefiles, `setup.py`). GitHub doesn't pass secrets to workflows triggered from forks, so the GCM token isn't exposed; keep `upload_to_gcm` off for PRs (as in the example).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Error response from daemon: denied` at "Initialize containers" | Calling repo has no access to the GHCR package, or the caller job lacks `packages: read` | Add the repo under *Manage Actions access*; add `permissions: packages: read` |
| `workflow was not found` | qse_pod's workflow isn't shared with the org | *Settings → Actions → Access* in qse_pod |
| Build fails at `git clone` | `QSE_TOKEN` missing/expired, or the runner can't reach github.ibm.com | Rotate the token; build from a machine with access |
| `QSE CLI not found` | Image built without the CLI | Rebuild with `--secret id=qse_token,...` |
| Java scanned without `-cf` | Maven/Gradle build failed (see the warning in the log) | Fix the build, or use `pre_build_command` + `skip_build` |
| `UPLOAD_TO_GCM=true but 'GCM_SERVER_URL' is not set` | Upload forced without config | Pass `gcm_server_url` and `gcm_bearer_token`, or use `auto` |
| `GCM client error HTTP 401/403` | Invalid or expired bearer token | Rotate `GCM_BEARER_TOKEN` |

---

## Disclaimer
- Created by Erwin Friethoff, Security Architect at IBM, using IBM Bob, our SDLC buddy.
- This is 100% free and open source and not in any way endorsed or supported by IBM. All done on personal title.
- If you have any questions, please reach out to me on Slack or LinkedIn. I'm happy to help.
- No warranty.
- GitHub Issues: report bugs or request features.
