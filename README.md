# EIDF GPU Service configs (eidf105)

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
the shared bases, edit the templates, or add a new folder for a different
tool/stack.
