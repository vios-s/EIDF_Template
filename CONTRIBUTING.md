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

## Alternative: pushing to Docker Hub if ECIR is full

ECIR (Harbor) storage is a shared, project-level quota — if a push starts
failing with something like `no space left`/`quota exceeded` rather than an
auth error, that's the registry being full, not your login. There's no
built-in overflow handling on EIDF's side, but `build.sh`'s "Registry host" /
"ECIR registry project" prompts are just plain strings — nothing hardcodes
`registry.eidf.ac.uk`, so you can point the exact same wizard at Docker Hub
instead:

```
Registry host [registry.eidf.ac.uk]: docker.io
ECIR registry project [eidf105]: <your-dockerhub-username>
```

(or non-interactively: `REGISTRY=docker.io PROJECT=<you> ./build.sh cuda`).
It builds and tags exactly the same way, then prints `docker login docker.io`
+ `docker push docker.io/<you>/cuda-eidf:latest` instead.

One catch: every job template's `imagePullSecrets: [eidf105-ecir-read-robot]`
is an ECIR-only credential — Kubernetes just ignores it for a registry it
doesn't match, so it's harmless to leave in, but it also means it does
**nothing** for a Docker Hub pull. That's fine if your Docker Hub repo is
public (anonymous pull just works); for a private repo you'd need to create
your own `kubernetes.io/dockerconfigjson` Secret from your Docker Hub
credentials and swap it into `imagePullSecrets` yourself. Treat this as a
temporary workaround, not a replacement for ECIR — switch back once there's
quota again (ask on Helpdesk, or see the storage-quota ticket already filed
for this project).

## Robot accounts (shared push/pull credentials)

The read-only `eidf105-ecir-read-robot` Secret already in `eidf105ns` is a
**robot account** — a project-level credential, not tied to any one person's
SAFE login, which is why every Job's `imagePullSecrets` can reference the
same one regardless of who deployed it. It's already set up; don't recreate
it.

A **read-write** robot account (so pushing doesn't need everyone's own,
regularly-expiring personal CLI Secret) does not currently exist for
`eidf105` — one was requested via Helpdesk, but the account it initially
pointed back to turned out to still be read-only (verified by an actual
failed `docker push` — `unauthorized: ... action: push`); that follow-up is
still unresolved as of this writing.

Checked EIDF's own docs
([registry FAQ](https://docs.eidf.ac.uk/services/registry/faq/),
[working with the registry](https://docs.eidf.ac.uk/services/registry/working-with/))
for a way around this — as of 2026-07-23, there is **no CLI or API command**
to create or regenerate a robot account yourself; it's Helpdesk-request-only.
EIDF's own docs note "new functionality soon to be added to the EIDF Portal
to allow project users to create read-only robot accounts" — read-only, and
not live yet. Personal push credentials (the CLI Secret each user copies from
their SAFE profile for `docker login`) have the same limitation: no
self-service regeneration command exists either, it's copy-from-dashboard
every time it expires. If EIDF ships either of these, this section should be
updated with the actual command.

## Managing secrets

**Never put an actual API key/token in a Dockerfile, `image.conf`, or any
committed yaml.** Anyone who can pull the image or read the repo gets it, and
Docker layers keep old values around even after you "remove" them in a later
layer.

The pattern used throughout this repo: keep secrets in a local `.env` file
(copy `.env.example` at the repo root — never commit the real one, it's
already gitignored, and it doesn't need to live inside this repo at all).
Convert it to a Kubernetes Secret with kubectl's built-in
`--from-env-file`, and reference the whole thing generically with
`envFrom: secretRef` in the Job — no per-variable wiring needed, so whatever
your `.env` contains (`HUGGINGFACE_TOKEN`, `WANDB_API_KEY`, anything) just
shows up as container env vars without any repo changes.

The job template has a `# <SECRET_ENV_HOOK>` marker line (at the container
level, alongside `env:`/`command:`), and `image.conf` sets
`SUPPORTS_ENV_SECRETS=yes` + `SECRET_DEFAULT_NAME` (a suggested Secret name)
for targets that should offer this. When the wizard runs and you opt in, it:

1. Asks for the **path to your `.env` file** and a **Kubernetes Secret name**
   to create it as — metadata only, it never opens or reads the file.
2. Substitutes a real `envFrom: [{ secretRef: { name: ... } }]` block into
   your generated `job.<you>.yaml`, replacing the marker line.
3. Prints a reminder, at the end, to actually create that Secret yourself:
   `kubectl create secret generic <name> --from-env-file=<path>`.

At no point does `build.sh` read, see, or store your `.env` file's actual
contents — that command is run directly by you, once, and the Secret lives
only in the cluster from then on. If you decline the prompt (or run
non-interactively, which skips job generation entirely), the marker line is
just deleted and the job yaml has no secret wiring at all.

Adding this to a new target is two changes: put `# <SECRET_ENV_HOOK>` at the
container level (not inside `env:`) in your `job.template.yaml`, and set
`SUPPORTS_ENV_SECRETS=yes` + `SECRET_DEFAULT_NAME` in `image.conf`. Leave
`SUPPORTS_ENV_SECRETS` unset (or `no`) if the target never needs secrets —
`build.sh` just skips the question.

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
   If the tool can use a secret (an API token, etc.), add a
   `# <SECRET_ENV_HOOK>` marker line where the wizard should insert it — see
   "Managing secrets" below, don't hand-write the secret block into the
   template itself.
3. `image.conf` — copy an existing one (e.g. `CUDA/image.conf`) and fill in:
   - `TARGET`/`IMAGE_NAME`/`HAS_BASE`/`BASE_IMAGE_NAME`/`HAS_TEMPLATE`/`DESCRIPTION`
   - one `JOB_MODE_<n>_NAME`/`_LABEL`/`_TEMPLATE` block per job mode the
     wizard should offer (add `_EXTRA_VAR`/`_EXTRA_PROMPT`/`_EXTRA_DEFAULT` if
     that mode needs one extra placeholder filled in, like CUDA's `COMMAND`
     or vllm's `MODEL`)
   - `HAS_SERVICE`/`SERVICE_TEMPLATE`/`SERVICE_JOB_MODE` if a Service should
     also be generated for one of the job modes (see `vllm/image.conf`)
   - `SUPPORTS_ENV_SECRETS`/`SECRET_DEFAULT_NAME` if you added a
     `<SECRET_ENV_HOOK>` marker in step 2

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
