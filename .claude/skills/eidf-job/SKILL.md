---
name: eidf-job
description: >
  Create or edit GPU workloads (Kubernetes Job YAML) for the EIDF GPU
  Service (group project eidf105, namespace eidf105ns). Use this skill
  WHENEVER the user wants to run, train, fine-tune, serve, or debug
  anything on "the cluster", "EIDF", "the GPUs", the H100s/A100s, or asks
  for a "job yaml", "job file", "pod", "interactive pod", "vllm server",
  or wants to change the GPUs/CPUs/memory/image of an existing
  job.<user>.yaml — even if they never say "EIDF" or "Kubernetes".
  Never write EIDF job YAML from scratch or from memory: this skill fills
  the group's standard templates so every job carries the required
  ownership labels and cluster conventions.
---

# EIDF GPU job specs — always from the group templates

People in this group run GPU workloads on the EIDF GPU Service by
`kubectl create`-ing a Kubernetes Job in the shared namespace
`eidf105ns`. The group maintains battle-tested templates; a hand-written
YAML almost always gets something wrong that the templates get right:

- **Ownership labels** (`owner` / `project` / `purpose` on the Job *and*
  its pod template). The shared namespace has ~20 users; these labels are
  how anyone — including cluster tooling like kubmonitor — can tell whose
  workload is whose (`kubectl get pods -l owner=<user>`). A job without
  them is anonymous and gets chased up by the admins. Never drop them.
- **Non-root as the actual user**: `runAsUser`/`runAsGroup` matching the
  user's NFS uid/gid, so files written to `/data` are owned correctly.
- **Working pull secret** (`eidf105-ecir-read-robot`), NFS mount, `/dev/shm`
  sizing, kueue queue label, `PYTHONUNBUFFERED=1` for live logs.

So: **locate the templates, fill the placeholders, keep everything you
don't have a reason to change.**

## Step 1 — locate the EIDF_Template repo

In order of preference:
1. The current directory (or a parent) is a clone — look for
   `build.sh` + `CUDA/job.template.yaml`.
2. A sibling/likely clone: `~/EIDF_Template`, `~/Project*/EIDF_Template`.
3. Otherwise clone it:
   `git clone https://github.com/vios-s/EIDF_Template`

## Step 2 — gather the facts (ask only what you can't discover)

| Fact | How to get it |
|---|---|
| username, uid, gid | `id -un`, `id -u`, `id -g` on this login VM — do NOT guess |
| what kind of job | infer from the request (see Step 3), confirm if ambiguous |
| GPU model + count | user's request, or recommend one (see below) |
| the command / model | user's request |
| secrets needed? | if the workload needs an HF token, W&B key, etc. |

**Scan before you ask.** Most sizing facts are discoverable — prefer a
quick scan over a questionnaire:

```bash
kubectl -n eidf105ns describe resourcequota   # GPUs/CPUs used vs quota RIGHT NOW
kubectl -n eidf105ns get localqueue eidf105ns-user-queue   # queue pressure
```

Fold what you see into the recommendation ("10/12 GPUs are in use, a
4-GPU job will queue — 2 GPUs would start now"). If the user's project
code is at hand, read the obvious signals instead of asking: the model
name/size in their configs, `num_workers` (drives CPU count),
batch size and precision (drive VRAM). When unsure about the current
GPU lineup, check <https://docs.eidf.ac.uk/services/gpuservice/>.

**Right-size instead of defaulting.** If the user didn't specify
resources — or their numbers look badly mismatched to the task — ask
one round of short questions for whatever the scan couldn't answer
(which model / roughly how many parameters, training or inference,
full fine-tune / LoRA / just serving, how many runs in parallel) and
recommend a fit.

Rough VRAM math per model parameter: inference ≈ 2 bytes (bf16) plus ~20%
overhead; LoRA/QLoRA fine-tune ≈ 2–4 bytes; full fine-tune with Adam ≈
16–18 bytes. So a 7B model serves on a 40GB A100, LoRA-tunes on one
80GB card, but full-tunes only sharded across many. Point small
debug/test workloads at MIG slices. Remember the project quota (~12
GPUs shared by the whole group): N parallel runs × G GPUs each all
count against it, so recommend the smallest setup that works and
staggering runs when someone wants a big sweep. If the user hears the
recommendation and still wants their own numbers, use theirs — say the
trade-off in one sentence and move on; it's their job, not yours.

## Step 3 — pick the template by purpose

| User wants to… | Template | `purpose` label |
|---|---|---|
| run a training/batch script to completion | `CUDA/job.template.yaml` | `batch` |
| a shell to exec into (debug, dev, custom kernels) | `CUDA/job.interactive.yaml` | `interactive` |
| an interactive PyTorch/conda dev pod | `PyTorch_Docker/job.template.yaml` | `interactive` |
| serve an LLM with an OpenAI-compatible API | `vllm/job.template.yaml` (+ `vllm/service.template.yaml` if in-cluster access is needed) | `serving` |

The `purpose` label is already correct inside each template — don't
change it, it describes the template's job type.

## Step 4 — fill every placeholder, change nothing else

Copy the template to `job.<username>.yaml` and replace **all** of:

| Placeholder | Value |
|---|---|
| `<USERNAME>` | login account from `id -un` |
| `<USER_ID>` / `<GROUP_ID>` | from `id -u` / `id -g` |
| `<PROJECT>` | `eidf105` unless told otherwise |
| `<COMMAND>` | the user's command (CUDA batch template; it sits in a YAML block scalar, so quotes inside it are safe) |
| `<MODEL>` | HF model id (vllm template) |
| `<SECRET_ENV_HOOK>` | see Step 6 |

A leftover `<ANYTHING>` makes kubectl reject the file or, worse, ships a
literal `<USERNAME>` label. Grep for `<` before finishing. The
`image:` line may need the user's own tag (ECIR convention
`registry.eidf.ac.uk/eidf105/<image>:<username>`); ask if unclear.
If the user has never built their personal image, the pod can't pull it —
point them at `./build.sh` (interactive wizard) first, or mention it in
your hand-over notes so the first `kubectl create` isn't a surprise
ImagePullBackOff. (The vllm template uses the shared `:latest` image, so
it works without a personal build.)

## Step 5 — resources and GPU choice

- Keep `requests` and `limits` **identical** (cluster convention).
- Scale cpu/memory with the GPU count within one node
  (rule of thumb: 8 CPU + 32Gi per GPU; vllm wants more memory).
  Default project quota is ~100 CPU / 1 TiB / **12 GPUs** — requests
  beyond the quota just queue.
- GPU model goes in the `nodeSelector`. The authoritative list lives at
  <https://docs.eidf.ac.uk/services/gpuservice/> (see also
  `training/L1_getting_started/`); as of 2025 the valid
  `nvidia.com/gpu.product` values are:

  | Value | VRAM | Notes |
  |---|---|---|
  | `NVIDIA-H200` | 141GB | only 16 in the whole service — scarce |
  | `NVIDIA-H100-80GB-HBM3` | 80GB | plentiful but high demand |
  | `NVIDIA-A100-SXM4-80GB` | 80GB | good fallback |
  | `NVIDIA-A100-SXM4-40GB` | 40GB | fine for small models |
  | `NVIDIA-A100-SXM4-40GB-MIG-3g.20gb` | 20GB slice | small jobs |
  | `NVIDIA-A100-SXM4-40GB-MIG-1g.5gb` | 5GB slice | debugging/tests |

  A **misspelled value never schedules** — the pod sits Pending forever
  with no loud error, so copy exactly. Omitting the nodeSelector gives a
  *random* GPU type. For debug/interactive pods that mostly compile or
  test code, suggest a MIG slice instead of a whole H100 — it queues
  faster and doesn't burn a scarce GPU.
- `/dev/shm` (`dshm` volume `sizeLimit`) matters for PyTorch dataloaders —
  grow it with memory if the user hits shm errors.
- For batch jobs, offer `ttlSecondsAfterFinished: 1800` on the Job spec
  so finished jobs clean themselves up (the docs recommend it).

## Step 6 — secrets are never written into YAML

If the job needs an HF token / API key, do NOT paste it into the yaml,
a Dockerfile, or the chat. Replace the `# <SECRET_ENV_HOOK>` marker with:

```yaml
          envFrom:
            - secretRef:
                name: <username>-env
```

and tell the user to create the Secret themselves from a local `.env`:

```bash
kubectl -n eidf105ns create secret generic <username>-env --from-env-file=.env
```

If no secrets are needed, just delete the `<SECRET_ENV_HOOK>` line.

## Step 7 — check and hand over

1. If `kubmonitor` is installed, run `kubmonitor validate job.<username>.yaml`
   — it confirms the ownership labels survived. Fix anything it reports.
2. `kubectl -n eidf105ns create --dry-run=server -f job.<username>.yaml`
   runs the file through the real admission chain (kueue included)
   without creating anything — a free catch for schema mistakes.
3. Give the user the deploy commands:

```bash
kubectl -n eidf105ns create -f job.<username>.yaml
kubectl -n eidf105ns get pods -l owner=<username> -w
kubectl -n eidf105ns logs -f <pod-name>        # batch/serving
kubectl -n eidf105ns exec -it <pod-name> -- /bin/bash   # interactive
```

## If the job won't start (Pending / no GPUs of that type)

Users can NOT list cluster nodes (`kubectl get nodes` is Forbidden), so
you cannot check free GPUs directly. What you *can* do:

```bash
kubectl -n eidf105ns get localqueue eidf105ns-user-queue   # queue pressure
kubectl -n eidf105ns get workloads                          # is it admitted by kueue?
kubectl -n eidf105ns describe pod <pod>                     # scheduler events
```

Read the signals: workload not admitted → quota/queue congestion (wait
or shrink the request); admitted but pod `Unschedulable` with "node(s)
didn't match" → the GPU type is misspelled, unavailable to this
namespace, or fully occupied. In that case propose the fallback ladder
**H200 → H100-80GB → A100-80GB → A100-40GB → MIG slice**, and be
explicit about the VRAM step-down (e.g. a model chosen for H200's 141GB
may need a smaller batch, sharding, or quantization on an 80GB card) —
let the user decide rather than silently downgrading.

## Editing an existing job.<user>.yaml

Apply the requested change (GPUs, image, command, …) and leave the rest
intact — in particular the labels block, securityContext,
imagePullSecrets, and the NFS/dshm volumes. Keep requests = limits in
sync when changing resources. If the file is missing the ownership
labels (an old hand-written one), add them as part of the edit and
mention it to the user.
