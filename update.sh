#!/usr/bin/env bash
#
# update.sh — one-command Metabase chart update.
#
# Looks up the latest Metabase OSS release, bumps Chart.yaml + values.yaml,
# lints, packages, re-indexes the repo and pushes. Replaces bump_version.sh.
#
# Usage:
#   ./update.sh                      latest release, minor chart bump, one confirmation
#   ./update.sh -y                   no questions asked
#   ./update.sh --metabase v0.64.0   pin a specific Metabase version
#   ./update.sh --chart-bump patch   patch | minor | major   (default: minor)
#   ./update.sh --chart 0.21.0       set the chart version explicitly
#   ./update.sh --dry-run            show what would change, touch nothing
#   ./update.sh --no-push            commit locally, don't push
#   ./update.sh --no-readme          leave the README table alone
#
# Env: GITHUB_TOKEN is used for the GitHub API if set (avoids rate limits).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------- options ---
PIN_METABASE=""
CHART_BUMP="minor"
PIN_CHART=""
ASSUME_YES=false
DRY_RUN=false
DO_PUSH=true
DO_README=true
ALLOW_DIRTY=false

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --metabase|-m)   PIN_METABASE="${2:-}"; shift 2 ;;
    --chart-bump)    CHART_BUMP="${2:-}"; shift 2 ;;
    --chart)         PIN_CHART="${2:-}"; shift 2 ;;
    -y|--yes)        ASSUME_YES=true; shift ;;
    --dry-run|-n)    DRY_RUN=true; shift ;;
    --no-push)       DO_PUSH=false; shift ;;
    --no-readme)     DO_README=false; shift ;;
    --allow-dirty)   ALLOW_DIRTY=true; shift ;;
    -h|--help)       sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown option: $1 (try --help)" ;;
  esac
done

case "$CHART_BUMP" in patch|minor|major) ;; *) die "--chart-bump must be patch, minor or major" ;; esac

# ---------------------------------------------------------------- helpers ---
for bin in curl git helm sed; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is not installed"
done

# GNU sed wants -i, BSD/macOS sed wants -i ''
sedi() {
  local expr="$1" file="$2"
  if sed --version >/dev/null 2>&1; then sed -i -e "$expr" "$file"
  else sed -i '' -e "$expr" "$file"; fi
}

# highest semver on stdin (portable — no `sort -V` needed)
highest() { sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1; }

latest_metabase() {
  local api="https://api.github.com/repos/metabase/metabase/releases?per_page=100"
  local json tags
  json=$(curl -fsSL -H "Accept: application/vnd.github+json" \
           ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "$api") \
    || die "could not reach the GitHub API"

  # Metabase ships OSS as v0.x.y and Enterprise as v1.x.y in the same repo,
  # so only stable v0.* tags are of interest here.
  if command -v jq >/dev/null 2>&1; then
    tags=$(printf '%s' "$json" | jq -r '
      .[] | select(.draft == false and .prerelease == false)
          | .tag_name | select(test("^v0\\.[0-9]+\\.[0-9]+$"))')
  else
    tags=$(printf '%s' "$json" \
      | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"v0\.[0-9][0-9]*\.[0-9][0-9]*"' \
      | sed 's/.*"\(v0[^"]*\)"$/\1/')
  fi

  [[ -n "$tags" ]] || die "no stable v0.x.y releases found in the API response"
  printf 'v%s\n' "$(printf '%s\n' "$tags" | highest)"
}

# ------------------------------------------------------------ where we are --
[[ -f Chart.yaml && -f values.yaml ]] || die "run this from the chart root"

CUR_MB=$(sed -n 's/^appVersion:[[:space:]]*//p' Chart.yaml | tr -d '"'"'"' \r')
CUR_CHART=$(sed -n 's/^version:[[:space:]]*//p' Chart.yaml | tr -d '"'"'"' \r')
[[ -n "$CUR_MB" && -n "$CUR_CHART" ]] || die "could not read version/appVersion from Chart.yaml"

if ! $ALLOW_DIRTY && [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty — commit or stash first (or pass --allow-dirty)"
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)

# ------------------------------------------------------------ new versions --
if [[ -n "$PIN_METABASE" ]]; then
  NEW_MB="v${PIN_METABASE#v}"
else
  info "Checking metabase/metabase for the latest release…"
  NEW_MB=$(latest_metabase)
fi

if [[ "$NEW_MB" == "$CUR_MB" ]]; then
  ok "Already on the latest Metabase ($CUR_MB) — nothing to do."
  exit 0
fi

if [[ "$(printf '%s\n%s\n' "$CUR_MB" "$NEW_MB" | highest)" == "${CUR_MB#v}" ]]; then
  # An explicit --metabase pin is allowed to go backwards (rollbacks), the
  # automatic lookup never is.
  [[ -n "$PIN_METABASE" ]] || die "$NEW_MB is older than the current $CUR_MB — refusing to downgrade"
  printf '\033[33m  !\033[0m %s is older than the current %s — this is a downgrade\n' "$NEW_MB" "$CUR_MB"
fi

if [[ -n "$PIN_CHART" ]]; then
  NEW_CHART="$PIN_CHART"
else
  IFS=. read -r MAJ MIN PAT <<<"$CUR_CHART"
  case "$CHART_BUMP" in
    major) NEW_CHART="$((MAJ + 1)).0.0" ;;
    minor) NEW_CHART="${MAJ}.$((MIN + 1)).0" ;;
    patch) NEW_CHART="${MAJ}.${MIN}.$((PAT + 1))" ;;
  esac
fi

if [[ -f "metabase-${NEW_CHART}.tgz" ]]; then
  die "metabase-${NEW_CHART}.tgz already exists — pick another chart version"
fi

# ------------------------------------------------------------- sanity check --
info "Verifying metabase/metabase:${NEW_MB} exists on Docker Hub…"
if curl -fsSL -o /dev/null "https://hub.docker.com/v2/repositories/metabase/metabase/tags/${NEW_MB}"; then
  ok "image tag found"
else
  printf '\033[33m  !\033[0m could not confirm the image tag (Docker Hub unreachable or tag missing)\n'
  $ASSUME_YES || { read -r -p "    Continue anyway? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || exit 1; }
fi

# -------------------------------------------------------------- confirmation --
cat <<EOF

  Metabase   ${CUR_MB}  ->  ${NEW_MB}
  Chart      ${CUR_CHART}  ->  ${NEW_CHART}
  Branch     ${BRANCH}$( $DO_PUSH || echo "  (no push)" )

EOF

if $DRY_RUN; then
  ok "Dry run — no files touched."
  exit 0
fi

if ! $ASSUME_YES; then
  read -r -p "Proceed? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ------------------------------------------------- edit, with rollback safety --
TOUCH_README=false
if $DO_README && [[ -f README.md ]]; then TOUCH_README=true; fi

# The tree was clean when we started (unless --allow-dirty), so git is the
# backup: anything we write can be thrown away with a checkout.
restore() {
  if $ALLOW_DIRTY; then
    printf '\033[31m✗ failed\033[0m — tree started dirty, so nothing was reverted; check git status\n' >&2
  else
    git checkout -- Chart.yaml values.yaml README.md 2>/dev/null || true
    printf '\033[31m✗ failed\033[0m — reverted with git checkout\n' >&2
  fi
}
trap restore ERR

info "Updating manifests…"
sedi "s/^version:.*/version: ${NEW_CHART}/" Chart.yaml
sedi "s/^appVersion:.*/appVersion: ${NEW_MB}/" Chart.yaml
# only the tag inside the image: block, so nothing else can be caught by accident
sedi "/^image:/,/^[^[:space:]]/s/^\([[:space:]]*\)tag:.*/\1tag: ${NEW_MB}/" values.yaml
EDITED="Chart.yaml, values.yaml"
if $TOUCH_README; then
  sedi "/^| image\.tag/s/v[0-9][0-9.]*/${NEW_MB}/" README.md
  EDITED="$EDITED, README.md"
fi
ok "$EDITED"

grep -q "appVersion: ${NEW_MB}" Chart.yaml || die "Chart.yaml did not update as expected"
grep -q "tag: ${NEW_MB}" values.yaml    || die "values.yaml did not update as expected"

info "Linting…"
helm lint . >/dev/null
ok "chart is valid"

info "Packaging and re-indexing…"
helm package . >/dev/null
helm repo index --url https://rhansma.github.io/metabase-helm-chart/ .
ok "metabase-${NEW_CHART}.tgz + index.yaml"

trap - ERR

# ------------------------------------------------------------------- git ----
info "Committing…"
git add .
git commit -q -m "Bump version of metabase to ${NEW_MB}" \
              -m "Chart ${CUR_CHART} -> ${NEW_CHART}, Metabase ${CUR_MB} -> ${NEW_MB}"
ok "committed"

if $DO_PUSH; then
  git push origin "$BRANCH"
  ok "pushed to origin/${BRANCH}"
else
  ok "not pushed — run: git push origin ${BRANCH}"
fi

printf '\n\033[32mDone.\033[0m Metabase %s is live as chart %s.\n' "$NEW_MB" "$NEW_CHART"
