#!/usr/bin/env bash
###############################################################################
# Unified entrypoint for every image in this repo (CUDA, PyTorch_Docker,
# vllm, ...). Replaces the old per-folder build.sh / build-base.sh /
# quickstart.sh.
#
# Usage:
#   ./build.sh                       # full interactive wizard (asks everything,
#                                     # builds locally, writes job.<you>.yaml,
#                                     # then prints the push + deploy commands)
#   ./build.sh <target>               # non-interactive: just build the personal image
#   ./build.sh <target> --template    # non-interactive: build Dockerfile.template
#   ./build.sh <target> --base        # non-interactive: (shared-base targets) rebuild Dockerfile.base
#   ./build.sh --list                 # list available targets
#
# This script never runs `docker push` for you — it only ever builds locally
# and then prints the exact push command, so pushing to the shared registry
# is always something you explicitly run yourself.
#
# Env vars (all optional, used as defaults you can still override
# interactively): USERNAME, USER_ID, GROUP_ID, REGISTRY, PROJECT, IMAGE
# (non-interactive mode only).
#
# Adding a new target: create a new top-level folder with a Dockerfile and an
# `image.conf` (copy an existing one) — nothing in this script needs editing.
# See CONTRIBUTING.md.
###############################################################################
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ask() {  # ask PROMPT DEFAULT -> prints the chosen value
  local prompt="$1" default="$2" reply
  read -r -p "${prompt} [${default}]: " reply || true
  echo "${reply:-$default}"
}

esc_repl() {  # escape a string for use as a sed s### REPLACEMENT
  # Answers are free-form text (a shell command, a model name). Unescaped, two
  # characters break the substitutions below:
  #   &  means "the whole match" in a sed replacement, so a batch command of
  #      `python a.py && python b.py` silently becomes
  #      `python a.py <COMMAND><COMMAND> python b.py` — plausible-looking yaml
  #      that runs garbage.
  #   #  is the delimiter used below, so it aborts sed outright ("unknown option
  #      to `s'"), after the docker build has already succeeded.
  # Order matters: backslash first, or it double-escapes what follows.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  s="${s//#/\\#}"
  printf '%s' "$s"
}

confirm() {  # confirm PROMPT DEFAULT(y/n) -> exit status 0 = yes
  local prompt="$1" default="${2:-y}" reply
  read -r -p "${prompt} [${default}]: " reply || true
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# --- discover targets + job modes from */image.conf ---------------------------
declare -a TARGET_NAMES=()
declare -A TARGET_DIR=() TARGET_IMAGE_NAME=() TARGET_HAS_BASE=()
declare -A TARGET_BASE_IMAGE_NAME=() TARGET_HAS_TEMPLATE=() TARGET_DESCRIPTION=()
declare -A TARGET_HAS_SERVICE=() TARGET_SERVICE_TEMPLATE=() TARGET_SERVICE_JOB_MODE=()
declare -A TARGET_SUPPORTS_ENV_SECRETS=() TARGET_SECRET_DEFAULT_NAME=()
declare -A JOBMODE_COUNT=()
declare -A JOBMODE_NAME=() JOBMODE_LABEL=() JOBMODE_TEMPLATE=()
declare -A JOBMODE_EXTRA_VAR=() JOBMODE_EXTRA_PROMPT=() JOBMODE_EXTRA_DEFAULT=()

for conf in */image.conf; do
  [ -f "$conf" ] || continue
  dir="$(dirname "$conf")"
  TARGET="" IMAGE_NAME="" HAS_BASE=no BASE_IMAGE_NAME="" HAS_TEMPLATE=no DESCRIPTION=""
  HAS_SERVICE=no SERVICE_TEMPLATE="" SERVICE_JOB_MODE=""
  SUPPORTS_ENV_SECRETS=no SECRET_DEFAULT_NAME=""
  for i in 1 2 3; do
    eval "JOB_MODE_${i}_NAME=''; JOB_MODE_${i}_LABEL=''; JOB_MODE_${i}_TEMPLATE=''"
    eval "JOB_MODE_${i}_EXTRA_VAR=''; JOB_MODE_${i}_EXTRA_PROMPT=''; JOB_MODE_${i}_EXTRA_DEFAULT=''"
  done
  # shellcheck disable=SC1090
  source "$conf"
  if [ -z "$TARGET" ]; then
    echo "warning: ${conf} has no TARGET=, skipping" >&2
    continue
  fi
  TARGET_NAMES+=("$TARGET")
  TARGET_DIR["$TARGET"]="$dir"
  TARGET_IMAGE_NAME["$TARGET"]="$IMAGE_NAME"
  TARGET_HAS_BASE["$TARGET"]="$HAS_BASE"
  TARGET_BASE_IMAGE_NAME["$TARGET"]="$BASE_IMAGE_NAME"
  TARGET_HAS_TEMPLATE["$TARGET"]="$HAS_TEMPLATE"
  TARGET_DESCRIPTION["$TARGET"]="$DESCRIPTION"
  TARGET_HAS_SERVICE["$TARGET"]="$HAS_SERVICE"
  TARGET_SERVICE_TEMPLATE["$TARGET"]="$SERVICE_TEMPLATE"
  TARGET_SERVICE_JOB_MODE["$TARGET"]="$SERVICE_JOB_MODE"
  TARGET_SUPPORTS_ENV_SECRETS["$TARGET"]="$SUPPORTS_ENV_SECRETS"
  TARGET_SECRET_DEFAULT_NAME["$TARGET"]="$SECRET_DEFAULT_NAME"

  count=0
  for i in 1 2 3; do
    namevar="JOB_MODE_${i}_NAME"
    if [ -n "${!namevar}" ]; then
      count=$((count + 1))
      labelvar="JOB_MODE_${i}_LABEL"; tmplvar="JOB_MODE_${i}_TEMPLATE"
      extravar="JOB_MODE_${i}_EXTRA_VAR"; extrapromptvar="JOB_MODE_${i}_EXTRA_PROMPT"
      extradefaultvar="JOB_MODE_${i}_EXTRA_DEFAULT"
      JOBMODE_NAME["${TARGET}_${count}"]="${!namevar}"
      JOBMODE_LABEL["${TARGET}_${count}"]="${!labelvar}"
      JOBMODE_TEMPLATE["${TARGET}_${count}"]="${!tmplvar}"
      JOBMODE_EXTRA_VAR["${TARGET}_${count}"]="${!extravar}"
      JOBMODE_EXTRA_PROMPT["${TARGET}_${count}"]="${!extrapromptvar}"
      JOBMODE_EXTRA_DEFAULT["${TARGET}_${count}"]="${!extradefaultvar}"
    fi
  done
  JOBMODE_COUNT["$TARGET"]="$count"
done

list_targets() {
  echo "Available targets:"
  for t in "${TARGET_NAMES[@]}"; do
    printf "  %-10s %s\n" "$t" "${TARGET_DESCRIPTION[$t]}"
  done
}

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "list" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  list_targets
  exit 0
fi

INTERACTIVE=0
[ $# -eq 0 ] && INTERACTIVE=1
JOB_OUT="" SVC_OUT="" NAMESPACE=""

if [ "$INTERACTIVE" = 1 ]; then
  # --- fully interactive wizard ------------------------------------------------
  echo "== EIDF image build wizard =="
  echo
  echo "Which image do you want to build?"
  select t in "${TARGET_NAMES[@]}"; do
    [ -n "$t" ] && TARGET="$t" && break
  done

  DIR="${TARGET_DIR[$TARGET]}"
  IMAGE_NAME="${TARGET_IMAGE_NAME[$TARGET]}"
  HAS_BASE="${TARGET_HAS_BASE[$TARGET]}"
  BASE_IMAGE_NAME="${TARGET_BASE_IMAGE_NAME[$TARGET]}"
  HAS_TEMPLATE="${TARGET_HAS_TEMPLATE[$TARGET]}"

  echo
  declare -a MODE_OPTIONS=("personal — your own image")
  [ "$HAS_TEMPLATE" = yes ] && MODE_OPTIONS+=("template — group template, tagged with your username")
  [ "$HAS_BASE" = yes ] && MODE_OPTIONS+=("base — maintainer only: rebuild the shared base image")

  if [ "${#MODE_OPTIONS[@]}" -gt 1 ]; then
    echo "What do you want to build for '${TARGET}'?"
    select opt in "${MODE_OPTIONS[@]}"; do
      case "$opt" in
        personal*) MODE=personal ;;
        template*) MODE=template ;;
        base*)     MODE=base ;;
      esac
      [ -n "${opt:-}" ] && break
    done
  else
    MODE=personal
  fi

  echo
  if [ "$MODE" = base ]; then
    echo "(ECIR full/out of quota? Enter docker.io as the registry host and your"
    echo " Docker Hub username as the project to push there instead — see"
    echo " CONTRIBUTING.md's \"Alternative: pushing to Docker Hub\" section.)"
    REGISTRY=$(ask "Registry host" "${REGISTRY:-registry.eidf.ac.uk}")
    PROJECT=$(ask  "ECIR registry project" "${PROJECT:-eidf105}")
    USERNAME="${USERNAME:-$(id -un)}"; USER_ID="${USER_ID:-$(id -u)}"; GROUP_ID="${GROUP_ID:-$(id -g)}"
  else
    USERNAME=$(ask "Your username"        "${USERNAME:-$(id -un)}")
    USER_ID=$(ask  "Your uid"              "${USER_ID:-$(id -u)}")
    GROUP_ID=$(ask "Your gid"              "${GROUP_ID:-$(id -g)}")
    NAMESPACE=$(ask "Kubernetes namespace" "eidf105ns")
    echo "(ECIR full/out of quota? Enter docker.io as the registry host and your"
    echo " Docker Hub username as the project to push there instead — see"
    echo " CONTRIBUTING.md's \"Alternative: pushing to Docker Hub\" section.)"
    REGISTRY=$(ask "Registry host"         "${REGISTRY:-registry.eidf.ac.uk}")
    PROJECT=$(ask  "ECIR registry project" "${PROJECT:-eidf105}")

    count="${JOBMODE_COUNT[$TARGET]}"
    JOB_MODE_IDX=1
    if [ "$count" -gt 1 ]; then
      echo
      echo "What kind of Job do you want to deploy?"
      declare -a job_labels=()
      for i in $(seq 1 "$count"); do job_labels+=("${JOBMODE_LABEL[${TARGET}_${i}]}"); done
      select lbl in "${job_labels[@]}"; do
        for i in $(seq 1 "$count"); do
          [ "${JOBMODE_LABEL[${TARGET}_${i}]}" = "$lbl" ] && JOB_MODE_IDX="$i"
        done
        [ -n "${lbl:-}" ] && break
      done
    fi
    JOB_MODE_NAME="${JOBMODE_NAME[${TARGET}_${JOB_MODE_IDX}]}"
    JOB_TEMPLATE_FILE="${JOBMODE_TEMPLATE[${TARGET}_${JOB_MODE_IDX}]}"
    EXTRA_VAR="${JOBMODE_EXTRA_VAR[${TARGET}_${JOB_MODE_IDX}]}"
    EXTRA_VALUE=""
    if [ -n "$EXTRA_VAR" ]; then
      EXTRA_VALUE=$(ask "${JOBMODE_EXTRA_PROMPT[${TARGET}_${JOB_MODE_IDX}]}" "${JOBMODE_EXTRA_DEFAULT[${TARGET}_${JOB_MODE_IDX}]}")
    fi

    # Optional secrets (HF token, W&B key, etc.), fed from a local .env file
    # you create yourself. This script never reads that file or asks for its
    # contents — only its path (so it can tell you the exact kubectl command)
    # and the K8s Secret name to create it under.
    WANT_SECRET=0
    ENV_FILE="" SECRET_NAME=""
    if [ "${TARGET_SUPPORTS_ENV_SECRETS[$TARGET]}" = yes ]; then
      echo
      if confirm "Do you have a local .env file with secrets this job needs (HF token, W&B key, etc.)? This only asks for the file's path and a Secret name — never its contents." "n"; then
        WANT_SECRET=1
        ENV_FILE=$(ask "Path to your .env file" ".env")
        SECRET_NAME=$(ask "K8s Secret name to create it as (you create this yourself, see next steps)" "${TARGET_SECRET_DEFAULT_NAME[$TARGET]}")
      fi
    fi
  fi

  case "$MODE" in
    base)     IMAGE="${REGISTRY}/${PROJECT}/${BASE_IMAGE_NAME}:latest" ;;
    template) IMAGE="${REGISTRY}/${PROJECT}/${IMAGE_NAME}:${USERNAME}" ;;
    personal) IMAGE="${REGISTRY}/${PROJECT}/${IMAGE_NAME}:latest" ;;
  esac

  echo
  echo "About to build [${MODE}] for '${TARGET}':"
  echo "  image:  ${IMAGE}"
  if [ "$MODE" != base ]; then
    echo "  user:   ${USERNAME} (uid=${USER_ID}, gid=${GROUP_ID})"
    echo "  job:    ${JOB_MODE_NAME} -> will write ${DIR}/job.${USERNAME}.yaml"
    [ "${TARGET_HAS_SERVICE[$TARGET]}" = yes ] && [ "$JOB_MODE_NAME" = "${TARGET_SERVICE_JOB_MODE[$TARGET]}" ] \
      && echo "          + ${DIR}/service.${USERNAME}.yaml"
    [ "$WANT_SECRET" = 1 ] && echo "  secret: ${ENV_FILE} -> Secret '${SECRET_NAME}' (you create this yourself)"
  fi
  echo "  (this only builds locally — you push it yourself afterward)"
  echo
  if ! confirm "Proceed?" "y"; then
    echo "Aborted — nothing built."
    exit 0
  fi

else
  # --- non-interactive: ./build.sh <target> [--template|--base] --------------
  TARGET_ARG="${1:-}"
  if [ -n "${TARGET_DIR[$TARGET_ARG]+x}" ]; then
    TARGET="$TARGET_ARG"
    shift
  else
    echo "Unknown target: ${TARGET_ARG}" >&2
    list_targets
    exit 1
  fi

  DIR="${TARGET_DIR[$TARGET]}"
  IMAGE_NAME="${TARGET_IMAGE_NAME[$TARGET]}"
  HAS_BASE="${TARGET_HAS_BASE[$TARGET]}"
  BASE_IMAGE_NAME="${TARGET_BASE_IMAGE_NAME[$TARGET]}"
  HAS_TEMPLATE="${TARGET_HAS_TEMPLATE[$TARGET]}"

  MODE=personal
  for arg in "$@"; do
    case "$arg" in
      --template) MODE=template ;;
      --base) MODE=base ;;
      *) echo "Unknown option: ${arg}" >&2; exit 1 ;;
    esac
  done

  if [ "$MODE" = base ] && [ "$HAS_BASE" != yes ]; then
    echo "Target '${TARGET}' has no shared base image (no Dockerfile.base)." >&2
    exit 1
  fi
  if [ "$MODE" = template ] && [ "$HAS_TEMPLATE" != yes ]; then
    echo "Target '${TARGET}' has no separate Dockerfile.template — its Dockerfile" >&2
    echo "already is the shared/group image. Just run: ./build.sh ${TARGET}" >&2
    exit 1
  fi

  REGISTRY="${REGISTRY:-registry.eidf.ac.uk}"
  PROJECT="${PROJECT:-eidf105}"
  USERNAME="${USERNAME:-$(id -un)}"
  USER_ID="${USER_ID:-$(id -u)}"
  GROUP_ID="${GROUP_ID:-$(id -g)}"

  case "$MODE" in
    base)     IMAGE="${IMAGE:-${REGISTRY}/${PROJECT}/${BASE_IMAGE_NAME}:latest}" ;;
    template) IMAGE="${IMAGE:-${REGISTRY}/${PROJECT}/${IMAGE_NAME}:${USERNAME}}" ;;
    personal) IMAGE="${IMAGE:-${REGISTRY}/${PROJECT}/${IMAGE_NAME}:latest}" ;;
  esac
fi

# --- build (never pushes) -----------------------------------------------------
cd "$DIR"

case "$MODE" in
  base)
    echo ">> [${TARGET}] Building ${IMAGE} from Dockerfile.base"
    docker build -f Dockerfile.base -t "${IMAGE}" .
    ;;
  template)
    echo ">> [${TARGET}] Building ${IMAGE} for ${USERNAME} (uid=${USER_ID}, gid=${GROUP_ID}) from Dockerfile.template"
    docker build -f Dockerfile.template \
      --build-arg USERNAME="${USERNAME}" \
      --build-arg USER_ID="${USER_ID}" \
      --build-arg GROUP_ID="${GROUP_ID}" \
      -t "${IMAGE}" .
    ;;
  personal)
    echo ">> [${TARGET}] Building ${IMAGE} for ${USERNAME} (uid=${USER_ID}, gid=${GROUP_ID}) from Dockerfile"
    docker build \
      --build-arg USERNAME="${USERNAME}" \
      --build-arg USER_ID="${USER_ID}" \
      --build-arg GROUP_ID="${GROUP_ID}" \
      -t "${IMAGE}" .
    ;;
esac
echo ">> Built ${IMAGE}"

# --- interactive extra: write job (+ service) yaml -----------------------------
if [ "$INTERACTIVE" = 1 ] && [ "$MODE" != base ]; then
  JOB_OUT="job.${USERNAME}.yaml"
  sed_args=(
    -e "s#<USERNAME>#${USERNAME}#g"
    -e "s#<USER_ID>#${USER_ID}#g"
    -e "s#<GROUP_ID>#${GROUP_ID}#g"
    # Fills the eidf.ac.uk/project usage-accounting label (same id as the
    # registry project for this group).
    -e "s#<PROJECT>#${PROJECT}#g"
    -e "s#eidf105ns#${NAMESPACE}#g"
    # Replace the whole image line with $IMAGE (already computed per-mode
    # above: :latest for personal, :$USERNAME for template) rather than
    # patching registry/tag piecemeal — the template's hardcoded tag is only
    # ever correct for one of the two modes it's shared between.
    -e "s#^\(\s*\)image: .*#\1image: $(esc_repl "${IMAGE}")#"
  )
  if [ -n "$EXTRA_VAR" ]; then
    sed_args+=(-e "s#<${EXTRA_VAR}>#$(esc_repl "${EXTRA_VALUE}")#g")
  fi
  if [ "$WANT_SECRET" = 1 ]; then
    # Replace the marker with a real (uncommented) envFrom block — this
    # script never reads your .env file or sees any secret value, only the
    # Secret's name.
    secret_block="          envFrom:\n            - secretRef:\n                name: $(esc_repl "${SECRET_NAME}")"
    sed_args+=(-e "s#.*<SECRET_ENV_HOOK>.*#${secret_block}#")
  else
    sed_args+=(-e "/<SECRET_ENV_HOOK>/d")
  fi
  sed "${sed_args[@]}" "$JOB_TEMPLATE_FILE" > "$JOB_OUT"
  echo ">> Wrote ${DIR}/${JOB_OUT}"

  # If kubmonitor is installed, check the generated Job against the group's
  # usage-accounting label contract (kubmonitor_cli docs/LABELS.md). Purely
  # advisory — the build already succeeded.
  if command -v kubmonitor >/dev/null 2>&1; then
    kubmonitor validate "$JOB_OUT" || \
      echo ">> WARNING: ${JOB_OUT} does not satisfy the usage-accounting label contract (see above)"
  fi

  if [ "${TARGET_HAS_SERVICE[$TARGET]}" = yes ] && [ "$JOB_MODE_NAME" = "${TARGET_SERVICE_JOB_MODE[$TARGET]}" ]; then
    SVC_OUT="service.${USERNAME}.yaml"
    sed -e "s#<USERNAME>#${USERNAME}#g" "${TARGET_SERVICE_TEMPLATE[$TARGET]}" > "$SVC_OUT"
    echo ">> Wrote ${DIR}/${SVC_OUT}"
  fi
fi

# --- next steps: push + deploy, printed, never run automatically -------------
echo
echo "== Next steps =="
echo "1. Push it (this script never does this for you):"
echo "     docker login ${REGISTRY}   # if not already logged in"
echo "     docker push ${IMAGE}"
if [ "$INTERACTIVE" = 1 ] && [ "$MODE" != base ]; then
  if [ "$WANT_SECRET" = 1 ]; then
    echo
    echo "2. Create the Secret from your .env file (this reads ${ENV_FILE} on"
    echo "   YOUR machine when you run it — nothing from it passed through"
    echo "   this script):"
    echo "     kubectl -n ${NAMESPACE} create secret generic ${SECRET_NAME} --from-env-file=${ENV_FILE}"
    echo
    echo "3. Deploy:"
  else
    echo
    echo "2. Deploy:"
  fi
  echo "     kubectl -n ${NAMESPACE} create -f ${DIR}/${JOB_OUT}"
  [ -n "$SVC_OUT" ] && echo "     kubectl -n ${NAMESPACE} apply  -f ${DIR}/${SVC_OUT}"
  echo "     kubectl -n ${NAMESPACE} get pods -l owner=${USERNAME} -w"
  case "$JOB_MODE_NAME" in
    batch|serving) echo "     kubectl -n ${NAMESPACE} logs -f <pod-name>" ;;
    *)             echo "     kubectl -n ${NAMESPACE} exec -it <pod-name> -- /bin/bash" ;;
  esac
fi
