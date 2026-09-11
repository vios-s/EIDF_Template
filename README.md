# EIDF GPU Service configs

Docker + Kubernetes templates for running GPU workloads on the
[EIDF GPU Service](https://docs.eidf.ac.uk/services/gpuservice/), namespace
`eidf105ns`. Images are hosted on the group's own
[EIDF Container Image Registry (ECIR)](https://docs.eidf.ac.uk/services/registry/)
project, `registry.eidf.ac.uk/eidf105/`.

## Folders

| Folder                                | What it's for                                                       |
| -------------------------------------- | --------------------------------------------------------------------|
| [`vllm/`](vllm/README.md)              | Serve an OpenAI-compatible LLM (vLLM) from a GPU pod.                |
| [`CUDA/`](CUDA/README.md)              | CUDA devel image (nvcc + cuDNN) with conda on top, for training + custom kernels. |
| [`PyTorch_Docker/`](PyTorch_Docker/README.md) | Conda-based PyTorch dev pod for interactive work.             |

Each folder has its own README with the full build/deploy workflow. All three
follow the same pattern:

- **Ownership labels**: every Job template carries `owner`, `project` and
  `purpose` labels (filled in by the wizard), so it's always clear whose
  workload is whose — handy for `kubectl get pods -l owner=<you>` and for
  admins tidying up the shared namespace. Keep them if you hand-edit a Job.
- **Non-root by default**: the image bakes in a user matching *your* EIDF NFS
  uid/gid (`id` on the login VM), so `kubectl exec -it` drops you in as
  yourself, not root, with read/write access to the NFS share.
- **`*.template.yaml` / `Dockerfile.template`**: copy these, fill in the
  `<PLACEHOLDER>`s, and you have your own image + Job.
- **[`build.sh`](build.sh)**: the **one** entrypoint, at the repo root, for
  every image in this repo — not one script per folder. It reads a small
  `image.conf` descriptor from each folder to know what's buildable, so
  adding a new image later doesn't require editing this script. It only ever
  builds **locally** — it never runs `docker push` or `kubectl` for you, it
  prints those commands so you review and run them yourself.
  ```bash
  ./build.sh              # full interactive wizard — asks target, mode,
                           # username/uid/gid, namespace, registry/project,
                           # job type, confirms, builds, writes job.<you>.yaml
                           # (+ service.<you>.yaml for vllm serving), then
                           # prints the push + deploy commands. Every answer
                           # has a sensible default, just press Enter.
  ./build.sh cuda         # non-interactive: just build your personal image
  ./build.sh cuda --template   # non-interactive: group template, tagged :<you>
  ./build.sh cuda --base       # non-interactive: (CUDA/PyTorch_Docker only) rebuild the shared base
  ./build.sh --list            # list available targets
  ```
  Your uid/gid are baked in automatically via `id` either way.
- **Layered images** (CUDA, PyTorch_Docker): `Dockerfile`/`Dockerfile.template`
  build `FROM` a shared, pre-built `*-eidf-base` image (see each folder's
  "The base image" section) instead of reinstalling CUDA/PyTorch/conda from
  scratch every time. Only whoever maintains that base runs
  `./build.sh <target> --base`; everyone else's normal build already points
  at the pushed result.
- **Secrets** (e.g. a Hugging Face token): keep them in a local `.env` file
  (copy [`.env.example`](.env.example) — it's gitignored, and doesn't need to
  live inside this repo at all). The wizard asks for its **path** and a
  Kubernetes **Secret name**, never its contents, wires up `envFrom` in your
  Job, and reminds you to create the Secret yourself with
  `kubectl create secret generic <name> --from-env-file=<path>`. Never put a
  real token in a Dockerfile or any committed file — see each folder's
  "Managing secrets" section.

## Using an AI assistant

This repo ships a Claude Code skill (`.claude/skills/eidf-job/`) that
teaches the AI our cluster's rules, so instead of inventing Kubernetes
YAML from memory it fills the group templates with your real uid/gid and
the ownership labels, right-sizes the resources, and checks its own
output. You still review and `kubectl create` the file yourself.

### Install (pick one)

- **Zero setup**: clone this repo, `cd` in, run Claude Code — the skill
  loads automatically. Best when starting a new job from scratch.
- **One-time personal install** — works from *any* directory afterwards
  (including your own projects and existing `job.<you>.yaml` files):

  ```bash
  mkdir -p ~/.claude/skills/eidf-job
  curl -fsSL https://raw.githubusercontent.com/vios-s/EIDF_Template/main/.claude/skills/eidf-job/SKILL.md \
    -o ~/.claude/skills/eidf-job/SKILL.md
  ```

  Or simply tell Claude Code: *"install the eidf-job skill from the
  vios-s/EIDF_Template repo"* — it does the copy for you. Re-run either
  to update.

### What you can ask

Plain English is enough — some examples that all work:

- "make me a job to train my model on 2 H100s, command is `python train.py`"
- "give me a pod I can exec into to debug cuda kernels"
- "serve Qwen2.5-7B with vllm on one GPU"
- "bump my job to 4 GPUs and 128Gi" *(edits your existing yaml, keeps the labels)*
- "set up a job for my experiment, not sure what resources I need"
- "my job's been Pending for an hour, why?"

### What it does for you

- **Right-sizing**: scans your config files (model size, `num_workers`,
  batch size) and the live namespace quota/queue before recommending
  GPUs/CPU/memory — and tells you when a request can never schedule
  (e.g. >12 GPUs). Your own numbers always win if you insist.
- **GPU picking**: knows the full `nvidia.com/gpu.product` list from the
  [EIDF docs](https://docs.eidf.ac.uk/services/gpuservice/) including
  MIG slices for small/debug jobs, that a misspelled value pends
  forever, and the fallback ladder when your first choice is scarce.
- **Pending-job triage**: reads kueue admission + pod events to tell
  "quota queueing" apart from "wrong/unavailable GPU type".
- **Secrets discipline**: tokens go into a K8s Secret via `envFrom`,
  never into the yaml or the chat.
- **Self-checks**: `kubmonitor validate` (ownership labels) and a
  server-side `--dry-run` through the real admission chain before it
  hands you the file.

## Checking your job's logs

Anything your job writes to **stdout/stderr** is visible live, without
touching the NFS:

```bash
kubectl -n eidf105ns logs -f <pod-name>        # follow live
kubectl -n eidf105ns logs <pod-name> --tail=200
```

or interactively: run [`kubmonitor eidf105ns`](https://github.com/vios-s/kubmonitor_cli),
arrow-key onto your pod and press **Enter** for a scrollable, auto-refreshing
log view (`u` shows GPU allocation per user).

To make sure your output actually shows up there:

- **Just `print()` / `logging` normally** — stdout is the pod log. Don't
  redirect everything into a file on the NFS or you'll be blind in
  `kubectl logs`; if you want a file too, `tee` it:
  `python train.py 2>&1 | tee /data/users/<you>/run.log`.
- The templates already set `PYTHONUNBUFFERED=1`, so Python output
  appears immediately (no need for `python -u` or `flush=True`).
- `tqdm` progress bars write to stderr and show up fine — but prefer a
  sensible update interval (`miniters`/`mininterval`) so the log isn't
  99% carriage returns.
- Crashed pod? `kubectl -n eidf105ns logs <pod-name> --previous` shows
  the logs of the previous attempt.

## If you're a new colleague picking this up

Use the `*.template.*` files, not any file with someone else's username in
its name (e.g. `job.yyx.yaml`) — those are one person's concrete instance, not
generally reusable. In this repo those personal instance files (and one
person's working files under `CUDA/`) are `.gitignore`d, so you likely won't
even see them here.

One-time setup, shared across all three folders:
1. `docker login registry.eidf.ac.uk` (SAFE username + CLI Secret from your
   SAFE profile) — needed to **push** your own images.
2. Nothing else. **Pulling** already works out of the box: EIDF provisioned a
   read-only robot account for `eidf105` as a Secret already sitting in
   `eidf105ns` (`eidf105-ecir-read-robot`), and every Job in this repo already
   references it. Don't create or edit that Secret yourself.

See any folder's README for the exact commands, or
[CONTRIBUTING.md](CONTRIBUTING.md) for how to build your own image on top of
the shared bases, edit the templates, add a new folder for a different
tool/stack, push to Docker Hub instead if ECIR runs out of space, or how
robot accounts (shared push/pull credentials) actually work in this project.
