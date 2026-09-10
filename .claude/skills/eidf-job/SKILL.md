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
| GPU model + count | user's request; default 1× H100 if unstated |
| the command / model | user's request |
| secrets needed? | if the workload needs an HF token, W&B key, etc. |

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

## Step 5 — resources

- Keep `requests` and `limits` **identical** (cluster convention).
- Scale cpu/memory with the GPU count within one node
  (rule of thumb: 8 CPU + 32Gi per GPU; vllm wants more memory).
- GPU model goes in the `nodeSelector`. Valid values include:
  `NVIDIA-H200`, `NVIDIA-H100-80GB-HBM3`, `NVIDIA-A100-SXM4-80GB`,
  `NVIDIA-A100-SXM4-40GB`.
- `/dev/shm` (`dshm` volume `sizeLimit`) matters for PyTorch dataloaders —
  grow it with memory if the user hits shm errors.

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
2. Give the user the deploy commands:

```bash
kubectl -n eidf105ns create -f job.<username>.yaml
kubectl -n eidf105ns get pods -l owner=<username> -w
kubectl -n eidf105ns logs -f <pod-name>        # batch/serving
kubectl -n eidf105ns exec -it <pod-name> -- /bin/bash   # interactive
```

## Editing an existing job.<user>.yaml

Apply the requested change (GPUs, image, command, …) and leave the rest
intact — in particular the labels block, securityContext,
imagePullSecrets, and the NFS/dshm volumes. Keep requests = limits in
sync when changing resources. If the file is missing the ownership
labels (an old hand-written one), add them as part of the edit and
mention it to the user.
