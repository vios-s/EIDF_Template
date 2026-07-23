# Using and extending these templates

This is for colleagues who want to go beyond "just deploy the template" —
building your own image on top of the shared base, editing the Jobs, or
adding a new folder for a different tool/stack entirely. If you just want to
get a pod running, see the root [README.md](README.md) and the folder's own
README — this doc is about the *next* step.

## How the repo is put together

One entrypoint, [`build.sh`](build.sh), lives at the **repo root** and
handles every image — there's no per-folder `build.sh`/`quickstart.sh` to
avoid duplicating the same script three times. Run with no arguments it's a
full interactive wizard (pick a target, pick a mode, answer a few questions,
confirm) that builds **locally** and writes `job.<you>.yaml`; run with a
target argument it's non-interactive for scripting. Either way it never runs
`docker push` or `kubectl` for you — it only ever prints those commands. It
works off a small `image.conf` descriptor in each folder, so adding a new
image doesn't mean editing `build.sh` itself — see "Adding a new folder"
below.

Three independent folders (`CUDA/`, `PyTorch_Docker/`, `vllm/`), each
self-contained and following the same conventions:

```
build.sh                  # the one entrypoint, at the repo root

<folder>/
  Dockerfile.base          # (CUDA, PyTorch_Docker only) shared, maintainer-built
  Dockerfile               # personal image — FROM the base + your user
  Dockerfile.template      # colleague template — FROM the base + your user
  image.conf               # descriptor read by the root build.sh (image name,
                            # base/template flags, job modes it can generate)
  job.template.yaml        # copy, fill in <PLACEHOLDER>s
  job.interactive.yaml     # (some folders) keep-alive debug pod template
  job.<you>.yaml           # your generated instance — gitignored, not shared
  README.md
```

`vllm/` doesn't have a `Dockerfile.base` split — its image is already thin
enough (a few `apt-get` packages on top of `vllm/vllm-openai`) that there's
no meaningful reinstall cost to share.

Every Dockerfile in this repo does the same three things, in this order:
1. `FROM` a base image — either the shared `*-eidf-base` image, or (for
   `vllm/`) directly the upstream image.
2. Create a non-root user matching **your** EIDF NFS uid/gid (see the exact
   script below).
3. `USER <you>` + whatever packages/env you need.

## Building your own image on top of the shared base

Don't fork `Dockerfile.template` for a one-off customization — write a new,
small Dockerfile `FROM` the already-built shared base instead. It reuses
every cached layer (CUDA/PyTorch/conda already installed), so your build only
pays for what you add.

```dockerfile
FROM registry.eidf.ac.uk/eidf105/cuda-eidf-base:latest    # or pytorch-eidf-base

ARG USERNAME=you
ARG USER_ID=1000
ARG GROUP_ID=1000

# Robust non-root user creation — copy this verbatim, don't simplify it.
# See "Why the user-creation script looks like this" below for why every
# clause here exists.
RUN existing_user="$(getent passwd ${USER_ID} | cut -d: -f1)"; \
    if [ -n "$existing_user" ] && [ "$existing_user" != "${USERNAME}" ]; then \
        userdel -r "$existing_user" 2>/dev/null || userdel -f "$existing_user" 2>/dev/null || true; \
    fi \
    && if ! getent group ${GROUP_ID} >/dev/null; then \
        groupadd -g ${GROUP_ID} ${USERNAME}; \
    fi \
    && if getent passwd ${USERNAME} >/dev/null; then \
        usermod -u ${USER_ID} -g ${GROUP_ID} -d /home/${USERNAME} -m ${USERNAME}; \
    else \
        useradd -m -u ${USER_ID} -g ${GROUP_ID} -s /bin/bash ${USERNAME}; \
    fi \
    && mkdir -p /home/${USERNAME} \
    && chown -R ${USER_ID}:${GROUP_ID} /home/${USERNAME}

ENV HOME=/home/${USERNAME}
USER ${USERNAME}
RUN conda init bash        # skip this line for vllm — it has no conda

# --- your stuff ---
RUN mamba install -y my-package
# or: RUN pip install my-package
```

Build & push it under your own image name/tag (not `cuda-eidf`/`pytorch-eidf`
— those are the group's shared ones):

```bash
docker login registry.eidf.ac.uk
docker build --build-arg USERNAME=<you> --build-arg USER_ID=<uid> --build-arg GROUP_ID=<gid> \
  -t registry.eidf.ac.uk/eidf105/<your-image-name>:<you> .
docker push registry.eidf.ac.uk/eidf105/<your-image-name>:<you>
```

Then copy `job.template.yaml`, point `image:` at your new tag, and deploy as
usual.

### Why the user-creation script looks like this

It looks over-engineered for "just make a user" — it isn't. Real bugs, all
caught by actually deploying to the cluster rather than just building
locally:

- **Upstream images already have a user at your target uid.** Ubuntu 24.04
  base images (which `nvidia/cuda:*-ubuntu24.04` and newer `pytorch/pytorch`
  tags are built on) ship a default `ubuntu` account at **uid 1000** — the
  same uid every template defaults to. A plain `useradd -u 1000 ...` fails
  with `UID 1000 is not unique`. The script above deletes whatever account is
  squatting on your target uid first.
- **Upstream images may already have a user with your target name.**
  `vllm/vllm-openai` ships its own `vllm` user at uid 2000. If your `USERNAME`
  happens to collide with an existing name (even at a different uid),
  `useradd` fails with `user 'X' already exists`. The script `usermod`s the
  existing account instead of trying to create a duplicate.

If you're writing a Dockerfile from scratch for a new base image, keep this
exact block — don't go back to a plain `groupadd && useradd`, you may not hit
these on your first build but a colleague on a different day very well might.

## Editing the Job/Service YAML

- **Resources / GPU type**: edit `resources.requests`/`limits` and
  `nodeSelector.nvidia.com/gpu.product` directly. See the `# Pick a GPU type`
  comment in each template for the current options.
- **A different namespace or ECIR project**: the `build.sh` wizard asks for
  both interactively; by hand, it's `sed`-replacing `eidf105ns` (Kueue queue
  name) and `registry.eidf.ac.uk/eidf105/` in your copied file. Also check whether
  the new namespace has its own read-only ECIR pull secret already
  provisioned, or whether you need to request one (see the README's
  "One-time registry setup").
- **`/data/users/<you>/` might not be your actual folder.** This NFS share
  was populated over years with a mix of conventions — some folders are the
  Unix username, some are a first name, inconsistently. Before pointing
  `HF_HOME`/`TORCH_HOME`/anything else at it, `ls /data/users/` from an
  interactive pod and confirm you can actually write there
  (`touch /data/users/<name>/.write-test`). Writing to the wrong folder
  doesn't loudly fail — the directory might just belong to someone else and
  silently reject the write, or belong to `nobody` and let it through into a
  folder nobody's job ever reads from again.
- **A batch command that reads project code from the NFS**: the Dockerfiles'
  `WORKDIR` is your `$HOME`, not a path on the NFS mount, and none of them
  `COPY` any project script into the image. If your `args:` command runs a
  script (like the old `train.sh` used to), either `COPY` it into your own
  derived image (see above) or `cd /data/users/<you>/wherever` first in the
  command.

## Maintaining `Dockerfile.base` (CUDA, PyTorch_Docker)

Only touch this if you're deliberately changing something everyone in the
group inherits (new CUDA/PyTorch version, new shared apt package, etc.) —
most changes belong in your own derived Dockerfile instead (see above).

```bash
./build.sh cuda --base       # or: ./build.sh pytorch --base
# builds *-eidf-base:latest locally — review, then push it yourself:
docker login registry.eidf.ac.uk
docker push registry.eidf.ac.uk/eidf105/cuda-eidf-base:latest
```

Everyone else's next `./build.sh <target>` picks up the change automatically
once it's pushed — nothing for them to do. Test your change locally first
(`docker build -f CUDA/Dockerfile.base CUDA` — no `--build-arg`s needed,
there's no user in this layer yet) before pushing, since a broken base blocks
everyone's next build.

## Adding a new folder for a different tool/stack

Follow the existing structure so the templates stay predictable for whoever
uses them next:

1. `Dockerfile.base` (if the setup is nontrivial/slow) + `Dockerfile` +
   `Dockerfile.template`, using the non-root user-creation block above.
2. `job.template.yaml` (+ `job.interactive.yaml` if a keep-alive/debug mode
   makes sense for this tool) with `<USERNAME>`/`<USER_ID>`/`<GROUP_ID>`
   placeholders (and any extra placeholder your job needs, e.g. `<COMMAND>`),
   `imagePullSecrets: [eidf105-ecir-read-robot]`, and the NFS volume mount.
3. `image.conf` — copy an existing one (e.g. `CUDA/image.conf`) and fill in:
   - `TARGET`/`IMAGE_NAME`/`HAS_BASE`/`BASE_IMAGE_NAME`/`HAS_TEMPLATE`/`DESCRIPTION`
   - one `JOB_MODE_<n>_NAME`/`_LABEL`/`_TEMPLATE` block per job mode the
     wizard should offer (add `_EXTRA_VAR`/`_EXTRA_PROMPT`/`_EXTRA_DEFAULT` if
     that mode needs one extra placeholder filled in, like CUDA's `COMMAND`
     or vllm's `MODEL`)
   - `HAS_SERVICE`/`SERVICE_TEMPLATE`/`SERVICE_JOB_MODE` if a Service should
     also be generated for one of the job modes (see `vllm/image.conf`)

   This one file is what makes the new folder show up in `./build.sh --list`
   and fully drives the interactive wizard — nothing to change in `build.sh`
   itself.
4. `README.md` — Files table, registry setup, build & push, deploy, notes.
5. Add the folder to the root `README.md`'s table.
6. Update `.gitignore` if the new folder needs its own personal-file
   exclusions beyond the generic `job.*.yaml`/`service.*.yaml` patterns
   already there.

## Testing before you rely on it

1. **Local build**: `docker build ...` and `docker run --rm <image> bash -lc
   "whoami; id; python -c 'import torch'"` (adjust for your stack) — catches
   most user-creation and package-install issues without touching the
   cluster.
2. **Real deploy, once**: push to ECIR, deploy the Job for real, `kubectl exec
   -it` in and check identity/GPU/NFS write access, then delete the Job. Some
   things — like the NFS folder-naming inconsistency above — only show up
   against the real cluster, not in a local `docker run`.
3. Give the pod a short `activeDeadlineSeconds` and `ttlSecondsAfterFinished`
   while testing, and `kubectl delete job` promptly once you're done — this
   is a shared, actively-used namespace with other real GPU jobs running.
