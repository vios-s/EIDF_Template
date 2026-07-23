# PyTorch dev image on the EIDF GPU Service

A conda-based PyTorch dev pod: build the image, launch a keep-alive Job, then
`kubectl exec -it` in and work interactively as yourself (not root), with a
conda env active by default and the NFS share mounted read/write.

## Files

| File                  | Purpose                                                              |
| --------------------- | ---------------------------------------------------------------------|
| `Dockerfile.base`     | Shared base (PyTorch + apt tools + conda) — maintainer-built, see "The base image". |
| `Dockerfile`          | Personal image (yyx): base + your uid/gid baked in.                  |
| `Dockerfile.template` | Group template — base + packages left for you to add.               |
| `image.conf`          | Descriptor read by the repo-root `build.sh` — see below.             |
| `job.yyx.yaml`        | Concrete keep-alive pod for user `yyx` (uid 47259, gid 4542).        |
| `job.template.yaml`   | Keep-alive pod template — copy & fill `<PLACEHOLDER>`s.              |

## 1. One-time registry setup

Images are hosted on the **EIDF Container Image Registry (ECIR)**, not Docker
Hub — project `eidf105`'s images live under `registry.eidf.ac.uk/eidf105/`.

**Pulling (in the cluster):** nothing to do. EIDF already provisioned a
read-only robot account for this project as a Secret in `eidf105ns`, named
`eidf105-ecir-read-robot`, and every Job in this folder already references it
via `imagePullSecrets`. Don't recreate this Secret — it's shared, not
per-user.

**Pushing (building & uploading your image):** this needs your own personal
credentials, since the shared robot is read-only.
1. Grab your CLI Secret from your SAFE profile (dropdown under your username
   on `registry.eidf.ac.uk`).
2. Log in once per machine you build/push from:
   ```bash
   docker login registry.eidf.ac.uk    # username = SAFE username, password = CLI Secret
   ```
   Your CLI Secret has a limited validity period — if `docker push` starts
   failing with an auth error, just `docker login` again.

## 2. Build the image

New to this folder, on a different EIDF project, or just want the guided
path? All three folders share **one** entrypoint, `build.sh`, at the repo
root (not one per folder):

```bash
cd ..
./build.sh
```

With no arguments it's a full interactive wizard: pick `pytorch`, pick
personal/template, answer a handful of questions (each with a sensible
default — press Enter to accept one), confirm, and it builds the image
**locally** and writes a ready-to-use `job.<you>.yaml` (and prints the exact
`docker push` + `kubectl` commands for the next steps — see below, it never
pushes or deploys anything for you). Safe to re-run any time.

For scripting, `build.sh` also takes the target directly and skips all the
prompts (still local-build-only, same as above):

```bash
./build.sh pytorch                 # auto-detects USERNAME / USER_ID / GROUP_ID via `id`
# or explicitly:
USERNAME=yyx USER_ID=47259 GROUP_ID=4542 ./build.sh pytorch

# group members without a personal Dockerfile:
./build.sh pytorch --template      # tags it registry.eidf.ac.uk/eidf105/pytorch-eidf:<you>
```

## 3. Push it

`build.sh` deliberately never runs `docker push` itself — it prints the exact
command at the end, for you to run once you're happy with what got built:

```bash
docker login registry.eidf.ac.uk    # if not already
docker push registry.eidf.ac.uk/eidf105/pytorch-eidf:<tag>
```

## The base image

`Dockerfile` and `Dockerfile.template` both start `FROM
registry.eidf.ac.uk/eidf105/pytorch-eidf-base:latest` instead of the raw
PyTorch image. That base (built from `Dockerfile.base`) has the slow part
already done — PyTorch + apt tooling + conda/mamba — so every personal build
only adds a thin "create my user" layer instead of reinstalling all of that
from scratch. `../build.sh pytorch` already points at it (interactively or
not); you don't need to do anything differently.

Want to build your *own* image on top (extra packages, etc.), instead of
editing `Dockerfile.template` directly? Write a new Dockerfile that starts
from the same shared base:

```dockerfile
FROM registry.eidf.ac.uk/eidf105/pytorch-eidf-base:latest
ARG USERNAME=you
ARG USER_ID=1000
ARG GROUP_ID=1000
RUN useradd -m -u ${USER_ID} -g ${GROUP_ID} -s /bin/bash ${USERNAME}
USER ${USERNAME}
RUN conda init bash
RUN pip install my-package
```

Only whoever maintains `Dockerfile.base` needs `../build.sh pytorch --base`
(from the repo root, or pick "base" in the wizard) — and only when that file
itself changes (new PyTorch version, new shared tooling). It builds
`pytorch-eidf-base:latest` locally (push it the same manual way as any other
image); everyone else's next build picks up the change automatically once
it's pushed, no action needed on their end.

## 4. Deploy and exec in

If you used the wizard, it already wrote `job.<you>.yaml` with everything
filled in — just push the image (step 3) then:

```bash
kubectl -n eidf105ns create -f job.<you>.yaml
kubectl -n eidf105ns get pods -l owner=<you> -w        # wait for Running
kubectl -n eidf105ns exec -it <pod-name> -- /bin/bash
```

(`job.yyx.yaml` is the concrete example already checked in for `yyx`.) You
should land in your own home directory as your own user, with the `(base)`
conda env already active.

## 5. Tear down

```bash
kubectl -n eidf105ns delete job <job-name>     # or: -l owner=yyx
```

## Notes

- Namespace is assumed to be `eidf105ns`. Adjust `-n` if yours differs
  (`kubectl config view --minify | grep namespace`).
- `HF_HOME`/`TORCH_HOME` point at `/data/users/<you>/...` on the NFS so weights
  and checkpoints persist across runs instead of living in the ephemeral
  container layer.
- **`/data/users/<you>/` might not match your OS username.** This NFS share was populated over time with a mix of conventions (some folders are the unix username, some are a first name). Before deploying, `ls /data/users/` from an interactive pod to find YOUR actual folder, and edit the `HF_HOME`/`TORCH_HOME` paths in your Job to match — writing to the wrong one can silently fail or land in someone else's directory.
- No `fsGroup` is set on purpose: the NFS export is the whole share, and
  `fsGroup` would trigger a recursive chown of everything mounted.
