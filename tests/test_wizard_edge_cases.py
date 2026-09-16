#!/usr/bin/env python3
"""Drive build.sh with adversarial answers and check the YAML it writes.

Every check corresponds to something the Kubernetes API server rejects at
`kubectl create` — a failure the wizard would otherwise let through, and that
the user only discovers after the image has already built.

    python3 tests/test_wizard_edge_cases.py

Needs PyYAML, and shims a fake `docker` per case so no image is ever built.

If a kubeconfig reaches a cluster, each generated manifest is additionally
pushed through `kubectl create --dry-run=server`. That creates nothing, but
it is the only way to check the *real* admission chain — kueue, the
pod-limits policy, name validation — rather than guessing with regexes here.
That distinction is not academic: the first version of this file asserted
names must be DNS-1123 *labels* and reported two bugs that did not exist.
Names are DNS-1123 *subdomains*, so dots are legal and over-long prefixes are
truncated rather than refused. Without a cluster those checks are skipped and
everything else still runs.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# k8s label VALUE: alphanumeric ends, [-_.alnum] inside, <=63. Empty is legal.
LABEL_VALUE = re.compile(r"^([a-zA-Z0-9]([-_.a-zA-Z0-9]{0,61}[a-zA-Z0-9])?)?$")
# DNS-1123 *subdomain*, the rule metadata.name / generateName is held to.
# Verified against the live API server: dots ARE allowed (it only warns that
# they are unwise in pod hostnames), but uppercase and '_' are rejected
# outright. Over-length is NOT an error — the server truncates a
# generateName prefix before appending its suffix.
DNS1123_SUBDOMAIN = re.compile(
    r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$")


def build(workdir, answers, target="1", mode="1"):
    """Run the wizard with `answers` piped in; return (rc, output, dir)."""
    env = dict(os.environ)
    env["PATH"] = f"{workdir}/fakebin:" + env["PATH"]
    env.pop("KUBMONITOR_CONFIG", None)
    stdin = "\n".join([target, mode] + answers) + "\n"
    p = subprocess.run(["./build.sh"], cwd=workdir, input=stdin,
                       capture_output=True, text=True, env=env, timeout=120)
    return p.returncode, p.stdout + p.stderr


def check_doc(doc, problems, where):
    """Assert one parsed manifest would survive the API server."""
    meta = doc.get("metadata") or {}
    name = meta.get("generateName") or meta.get("name") or ""
    # generateName is a *prefix*; the server appends ~5 chars.
    stem = name.rstrip("-") or name
    if not DNS1123_SUBDOMAIN.match(stem):
        problems.append(
            f"{where}: name {name!r} is not a valid RFC 1123 subdomain "
            f"(no '_', no uppercase) — the API server rejects this")

    label_sets = [("metadata", meta.get("labels") or {})]
    tpl = ((doc.get("spec") or {}).get("template") or {})
    if tpl:
        label_sets.append(("pod template", (tpl.get("metadata") or {})
                           .get("labels") or {}))
    for scope, labels in label_sets:
        for k, v in labels.items():
            if not LABEL_VALUE.match(str(v)):
                problems.append(
                    f"{where}: {scope} label {k}={v!r} is not a valid "
                    f"label value")
            if len(str(v)) > 63:
                problems.append(
                    f"{where}: {scope} label {k} value exceeds 63 chars")
        if "<" in str(labels):
            problems.append(f"{where}: {scope} has an unfilled placeholder")


def server_dry_run(path, namespace="eidf105ns"):
    """Push the file through the real admission chain, creating nothing.

    The strongest check available: catches schema errors, kueue's and the
    pod-limits policy's admission rules, and name validation — everything a
    regex here would only be guessing at. Returns None if unreachable.
    """
    try:
        p = subprocess.run(
            ["kubectl", "-n", namespace, "create", "--dry-run=server",
             "-f", path],
            capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode == 0:
        return []
    err = p.stderr.strip() or p.stdout.strip()
    if "Unable to connect" in err or "refused" in err:
        return None
    return [line for line in err.splitlines()
            if line.strip() and not line.startswith("Warning:")]


def run_case(name, answers, expect="valid", target="1", mode="1",
             expect_labels=None):
    """expect="valid": the wizard must produce a manifest the server accepts.
       expect="rejected": the wizard must refuse the input and write nothing.

    A wizard that re-prompts cannot be driven by a fixed answer list — the
    retry consumes the next answer and every later one shifts — so for bad
    input the only stable assertion is "refused, wrote nothing".
    """
    workdir = tempfile.mkdtemp(prefix="wiz_")
    shutil.rmtree(workdir)
    shutil.copytree(REPO, workdir)
    os.makedirs(f"{workdir}/fakebin", exist_ok=True)
    with open(f"{workdir}/fakebin/docker", "w") as f:
        f.write('#!/bin/bash\necho "[docker] $*"\n')
    os.chmod(f"{workdir}/fakebin/docker", 0o755)

    problems = []
    try:
        rc, out = build(workdir, answers, target, mode)
    except subprocess.TimeoutExpired:
        return name, ["wizard hung (likely stuck re-prompting on bad input)"]

    written = [os.path.join(dp, fn)
               for dp, _, fns in os.walk(workdir) for fn in fns
               if re.match(r"job\..+\.yaml$", fn)
               and fn not in ("job.template.yaml", "job.interactive.yaml")]

    if expect == "rejected":
        if written:
            problems.append(
                f"wizard accepted input it should have refused, and wrote "
                f"{os.path.basename(written[0])} (rc={rc})")
        elif rc == 0:
            problems.append("wizard wrote nothing but still exited 0")
        shutil.rmtree(workdir, ignore_errors=True)
        return name, problems

    if not written:
        problems.append(f"no job file written (rc={rc})")
        return name, problems

    for path in written:
        rel = os.path.relpath(path, workdir)
        try:
            docs = [d for d in yaml.safe_load_all(open(path)) if d]
        except yaml.YAMLError as exc:
            problems.append(f"{rel}: YAML does not parse: "
                            f"{str(exc).splitlines()[0]}")
            continue
        if not docs:
            problems.append(f"{rel}: parsed to nothing")
        for doc in docs:
            check_doc(doc, problems, rel)
            # Targeted: a guard that re-asks but then uses the rejected
            # answer anyway would still look "valid", so pin the labels
            # that the correction was supposed to reach.
            got = (doc.get("metadata") or {}).get("labels") or {}
            for key, want in (expect_labels or {}).items():
                if got.get(key) != want:
                    problems.append(
                        f"{rel}: label {key}={got.get(key)!r}, expected "
                        f"{want!r} (the corrected answer did not land)")
        server = server_dry_run(path)
        if server:
            for line in server[:3]:
                problems.append(f"{rel}: server rejected: {line.strip()}")
    shutil.rmtree(workdir, ignore_errors=True)
    return name, problems


# answers order (cuda/personal): username, uid, gid, namespace, registry,
#   ECIR project, research project, [job mode], secrets?, proceed?
def A(user="rasin", uid="5001", gid="5001", ns="eidf105ns",
      reg="registry.eidf.ac.uk", proj="eidf105", research="mri_recon",
      jobmode="1"):
    """Build the answer stream. Any field may be a list to model a field the
    wizard re-asks: [bad, good] = one rejected answer then a correction."""
    fields = [user, uid, gid, ns, reg, proj, research, jobmode, "n", "y"]
    out = []
    for f in fields:
        out.extend(f if isinstance(f, list) else [f])
    return out


CASES = [
    # (label, answers, expected outcome, labels the manifest must carry)
    ("baseline", A(), "valid", {"project": "mri_recon", "owner": "rasin"}),
    # Accounts of these shapes are real here — LABELS.md calls out
    # `ada_lovelace` — and k8s resource names allow neither '_' nor
    # uppercase. The name must be folded while `owner` keeps the account.
    ("account with underscore", A(user="ada_lovelace"), "valid",
     {"owner": "ada_lovelace"}),
    ("account with uppercase", A(user="AdaLovelace"), "valid",
     {"owner": "AdaLovelace"}),
    ("account with a dot", A(user="ada.lovelace"), "valid",
     {"owner": "ada.lovelace"}),
    ("very long account name", A(user="a" * 60), "valid", None),
    ("very long research project", A(research="r" * 63), "valid",
     {"project": "r" * 63}),
    ("research project with dots", A(research="mri.recon.v2"), "valid",
     {"project": "mri.recon.v2"}),
    # sed metacharacters. '&' is the dangerous one: in a replacement it
    # means "the whole match", so it used to corrupt the queue label into
    # something plausible rather than failing outright. After the guard,
    # the corrected namespace must be the one that reaches the label.
    ("namespace '#' then corrected", A(ns=["eidf105ns#x", "eidf105ns"]),
     "valid", {"kueue.x-k8s.io/queue-name": "eidf105ns-user-queue"}),
    ("namespace '&' then corrected", A(ns=["ns&amp", "eidf105ns"]),
     "valid", {"kueue.x-k8s.io/queue-name": "eidf105ns-user-queue"}),
    # These two only ever reach the image name, which is replaced wholesale,
    # so metacharacters in them are harmless.
    ("registry with '&'", A(reg="reg&istry.example.com"), "valid", None),
    ("ECIR project with '#'", A(proj="proj#1"), "valid", None),
    ("uid non-numeric then corrected", A(uid=["notanumber", "5001"]),
     "valid", None),
    ("research project with a space then corrected",
     A(research=["mri recon", "mri_recon"]), "valid",
     {"project": "mri_recon"}),
    ("research project empty then corrected",
     A(research=["", "mri_recon"]), "valid", {"project": "mri_recon"}),
    # Exhausting the retry limit must fail loudly, never write a manifest
    # built from a value the guard rejected.
    ("research project invalid every time",
     A(research=["a b", "c d", "e f", "g h"]), "rejected", None),
    ("uid non-numeric every time", A(uid=["x", "y", "z", "w"]),
     "rejected", None),
]

if __name__ == "__main__":
    failures = 0
    for name, answers, expect, labels in CASES:
        label, problems = run_case(name, answers, expect=expect,
                                   expect_labels=labels)
        if problems:
            failures += 1
            print(f"\n[FAIL] {label}")
            for p in problems:
                print(f"       - {p}")
        else:
            print(f"[ok]   {label}")
    print(f"\n{failures} of {len(CASES)} cases produced a broken manifest")
    sys.exit(1 if failures else 0)
