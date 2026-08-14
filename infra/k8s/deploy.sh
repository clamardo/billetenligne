#!/usr/bin/env bash
# Deploys BilletEnLigne to GKE, from a workstation.
#
#   ./infra/k8s/deploy.sh                    # build, push and roll everything at HEAD
#   ./infra/k8s/deploy.sh --tag 972e0fa      # roll a tag that is already pushed
#   ./infra/k8s/deploy.sh --no-build         # ditto, without building
#   ./infra/k8s/deploy.sh --no-migrate       # skip the schema step
#
# **The order is the point.** Migrations run to completion *before* any pod
# that reads the schema is rolled, and the roll does not start if they failed.
# The alternative — an init container, or a Helm hook — runs the migration once
# per replica: two runners racing, one of which loses to a primary key. That
# fails safely and looks like a flaky deploy, which is worse than failing.
#
# **It refuses a dirty tree.** The tag is a git sha, and a sha that does not
# describe what was built is a tag that lies in `kubectl describe` on the day
# somebody is trying to find out what is running.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="billetenligne"

: "${BEL_REGISTRY:?set BEL_REGISTRY, e.g. europe-west1-docker.pkg.dev/<project>/bel}"
: "${BEL_API_URL:?set BEL_API_URL, e.g. https://blt.cg — it is compiled into the web bundles}"

TAG="$(git -C "$HERE" rev-parse --short HEAD)"
BUILD=1
MIGRATE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tag)     TAG="$2"; shift 2 ;;
    --no-build)   BUILD=0; shift ;;
    --no-migrate) MIGRATE=0; shift ;;
    -h|--help)    sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

if [[ "$BUILD" == 1 && -n "$(git -C "$HERE" status --porcelain)" ]]; then
  red "── the tree is dirty"
  echo "   The tag is a git sha. Commit, or pass --tag to roll something that"
  echo "   is already pushed."
  exit 1
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "── namespace"
  kubectl apply -f "$HERE/infra/k8s/namespace.yaml"
fi

# The Secret is never in this repository and never applied from it. If it is
# not already in the cluster, stop here rather than rolling pods that will
# crash-loop on a missing signing seed — which is the correct behaviour of the
# API and a confusing way to find out.
if ! kubectl -n "$NAMESPACE" get secret bel-secrets >/dev/null 2>&1; then
  red "── the secret bel-secrets does not exist in $NAMESPACE"
  echo "   See infra/k8s/secrets.example.yaml — it names every key and holds"
  echo "   no values. The API will not start without TICKETS__SIGNINGSEED."
  exit 1
fi

if [[ "$BUILD" == 1 ]]; then
  echo "── building and pushing $TAG"
  BEL_REGISTRY="$BEL_REGISTRY" BEL_TAG="$TAG" "$HERE/tool/images.sh" --web --push
fi

if [[ "$MIGRATE" == 1 ]]; then
  echo "── schema"
  # Deleted first: a Job's pod template is immutable, so re-applying one that
  # already exists is an error rather than a re-run.
  kubectl -n "$NAMESPACE" delete job bel-migrate --ignore-not-found
  sed "s#image: bel-worker#image: $BEL_REGISTRY/bel-worker:$TAG#" \
    "$HERE/infra/k8s/migrate/job.yaml" | kubectl -n "$NAMESPACE" apply -f -

  if ! kubectl -n "$NAMESPACE" wait --for=condition=complete job/bel-migrate --timeout=10m; then
    red "── migrations did not complete — nothing has been rolled"
    kubectl -n "$NAMESPACE" logs job/bel-migrate --tail=50 || true
    exit 1
  fi
  kubectl -n "$NAMESPACE" logs job/bel-migrate --tail=10
fi

echo "── applying"
# `kustomize edit set image` would write the registry and the tag into
# `kustomization.yaml`, which is a file in git: every deploy would leave the
# tree dirty and the next one would refuse to run. The placeholder is
# substituted on the way to the cluster instead, so what is committed stays
# readable and says `REGISTRY`.
kubectl kustomize "$HERE/infra/k8s" \
  | sed -e "s#REGISTRY/bel-\([a-z]*\):latest#$BEL_REGISTRY/bel-\1:$TAG#g" \
  | kubectl apply -f -

echo "── waiting"
for deployment in bel-api bel-console bel-admin; do
  kubectl -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout=5m
done

green "── deployed $TAG"
kubectl -n "$NAMESPACE" get pods -o wide
