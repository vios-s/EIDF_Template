# vLLM on the EIDF GPU Service — group template (eidf105)

Serve any OpenAI-compatible LLM from a GPU pod and reach it from your local VM
via `kubectl port-forward`.

## Files

| File                   | Purpose                                                             |
| ---------------------- | ------------------------------------------------------------------- |
| `Dockerfile`           | Lean image on top of `vllm/vllm-openai`; bakes in your uid/gid.     |
| `image.conf`           | Descriptor read by the repo-root `build.sh` — see below.            |
| `job.template.yaml`    | Auto-serving Job template — copy & fill `<PLACEHOLDER>`s.           |
| `job.yyx.yaml`         | Concrete Job for user `yyx` (uid 47259, gid 4542).                  |
| `job.interactive.yaml` | Keep-alive pod; exec in and run `vllm serve` by hand (debug).       |
| `service.template.yaml`| Stable Service name for the pod — copy & fill `<PLACEHOLDER>`s.     |
| `service.yyx.yaml`     | Concrete Service for user `yyx` (`svc/vllm-yyx`).                   |

The group image is `registry.eidf.ac.uk/eidf105/vllm-eidf`. The only per-run placeholder
left to fill is `<MODEL>` (e.g. `Qwen/Qwen2.5-7B-Instruct`).

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

With no arguments it's a full interactive wizard: pick `vllm`, pick
serving-vs-interactive, answer a handful of questions (each with a sensible
default — press Enter to accept one), confirm, and it builds the image
**locally** and writes a ready-to-use `job.<you>.yaml` (+ `service.<you>.yaml`
in serving mode) — and prints the exact `docker push` + `kubectl` commands
for the next steps, it never pushes or deploys anything for you. Safe to
re-run any time.

For scripting, `build.sh` also takes the target directly and skips all the
prompts (still local-build-only, same as above). Bake in **your** uid/gid so
files written to the shared NFS are owned correctly — find them with `id`:

```bash
./build.sh vllm                 # auto-detects USERNAME / USER_ID / GROUP_ID via `id`
# or explicitly:
USERNAME=yyx USER_ID=47259 GROUP_ID=4542 ./build.sh vllm
```

`PROJECT` defaults to `eidf105`; override it (`PROJECT=... ./build.sh vllm`)
if you ever need to push to a different ECIR project. Each group member
builds their own tag if uid/gid differ, e.g.
`registry.eidf.ac.uk/eidf105/vllm-eidf:yyx`. Set `IMAGE=...` to override the
tag (non-interactive mode only).

## 3. Push it

`build.sh` deliberately never runs `docker push` itself — it prints the exact
command at the end, for you to run once you're happy with what got built:

```bash
docker login registry.eidf.ac.uk    # if not already
docker push registry.eidf.ac.uk/eidf105/vllm-eidf:latest
```

## Building your own image on top of this one

Need extra Python packages in the serving container (a custom vLLM plugin, a
tokenizer dependency, etc.)? Don't edit this `Dockerfile` — write a new one
`FROM` the already-built-and-pushed shared image instead, so you're not
redoing the (slow) vLLM install:

```dockerfile
FROM registry.eidf.ac.uk/eidf105/vllm-eidf:latest
USER root
RUN pip install --no-cache-dir my-package
USER vllm
```

Build & push that under your own tag (e.g. `vllm-eidf-custom:<you>`) and
point your Job's `image:` at it.

## 4. Deploy the serving Job

If you used the wizard, it already wrote `job.<you>.yaml` (+
`service.<you>.yaml` in serving mode) with everything filled in — just push
the image (step 3) then:

```bash
kubectl -n eidf105ns create -f job.<you>.yaml
kubectl -n eidf105ns apply  -f service.<you>.yaml    # serving mode only
kubectl -n eidf105ns get pods -l owner=<you> -w      # wait for Running/Ready
kubectl -n eidf105ns logs -f <pod-name>              # watch the model load
```

(`job.yyx.yaml` / `service.yyx.yaml` are the concrete examples already
checked in for `yyx`.)

Gated models (Llama, etc.) need a Hugging Face token:

```bash
kubectl -n eidf105ns create secret generic hf-token --from-literal=token=hf_xxx
# then uncomment the HF_TOKEN env block in the Job yaml
```

## 5. Port-forward to your VM

The Job stays running until you delete it. Once the pod is Ready, forward the
**Service** (stable name — no need to look up the random pod name):

```bash
kubectl -n eidf105ns port-forward svc/vllm-yyx 8000:8000
```

Leave that terminal open; in another one:

```bash
curl http://localhost:8000/v1/models

curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "<MODEL>", "messages": [{"role":"user","content":"Hello"}]}'
```

If you set `VLLM_API_KEY`, add `-H "Authorization: Bearer <key>"`.

## 6. Tear down

```bash
kubectl -n eidf105ns delete job <job-name>     # or: -l owner=yyx
kubectl -n eidf105ns delete -f service.yyx.yaml
```

## Tuning knobs

Edit the `vllm serve` args / env in the Job:

- `--tensor-parallel-size N` — shard across N GPUs (also bump `nvidia.com/gpu`).
- `--gpu-memory-utilization 0.90` — fraction of VRAM for KV cache.
- `--max-model-len 8192` — max context; lower it if you hit OOM.
- `--served-model-name my-name` — the id clients use, instead of the HF path.
- GPU type: `nodeSelector: nvidia.com/gpu.product` — `NVIDIA-H200`,
  `NVIDIA-H100-80GB-HBM3`, `NVIDIA-A100-SXM4-80GB`, `NVIDIA-A100-SXM4-40GB`.

## Notes

- Namespace is assumed to be `eidf105ns` (matches the Kueue queue). Adjust `-n`
  if yours differs (`kubectl config view --minify | grep namespace`).
- `HF_HOME` points at `/data/users/<you>/hf-cache` so weights download once to
  NFS and are reused across runs — no re-download, no fat container layers.
- **`/data/users/<you>/` might not match your OS username.** This NFS share was
  populated over time with a mix of conventions (some folders are the unix
  username, some are a first name). Before deploying, `ls /data/users/` from
  an interactive pod to find YOUR actual folder, and edit `HF_HOME` in your
  Job to match — writing to the wrong one can silently fail or land in
  someone else's directory.
- Jobs go through Kueue (`kueue.x-k8s.io/queue-name`); if the cluster is busy
  the pod stays `Pending`/`Admitted` until GPUs free up.
- No `fsGroup` is set on purpose: the NFS export is the whole share, and
  `fsGroup` would trigger a recursive chown of everything mounted.
