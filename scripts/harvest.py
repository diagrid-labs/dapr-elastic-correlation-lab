"""Pull daprd and control plane logs out of the cluster and bulk index them.

Stands in for the customer's Fluentd pipeline: it wraps each Dapr JSON log line
in the ECS-ish envelope a log shipper would add (@timestamp, message, log.level,
kubernetes.*) while keeping the Dapr fields at the top level, which is what makes
app_id, method and code addressable from a data view.
"""
import json, os, subprocess, sys, urllib.request

CTX = ["kubectl", "--context", os.environ.get("KUBE_CONTEXT", "minikube")]
ES = os.environ.get("ES_URL", "http://localhost:9200").rstrip("/")
INDEX = os.environ.get("LOG_DATA_STREAM", "logs-dapr-default")

def pods(ns, sel=None):
    cmd = CTX + ["-n", ns, "get", "pods", "-o", "json"]
    out = json.loads(subprocess.run(cmd, capture_output=True, text=True).stdout)
    return [(p["metadata"]["name"], [c["name"] for c in p["spec"]["containers"]]) for p in out["items"]]

def logs(ns, pod, container):
    r = subprocess.run(CTX + ["-n", ns, "logs", pod, "-c", container, "--tail=2000"],
                       capture_output=True, text=True)
    return r.stdout.splitlines()

docs = []
for ns in ("default", "dapr-system"):
    for pod, containers in pods(ns):
        for c in containers:
            if c not in ("daprd",) and not c.startswith("dapr-"):
                continue
            for line in logs(ns, pod, c):
                line = line.strip()
                if not line.startswith("{"):
                    continue  # plaintext klog / zap lines a json parser would drop or leave raw
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                ts = d.get("time") or d.get("ts")
                if not ts:
                    continue
                doc = {
                    "@timestamp": ts,
                    "message": d.get("msg", ""),
                    "log": {"level": d.get("level", "")},
                    "kubernetes": {
                        "namespace": ns,
                        "pod": {"name": pod},
                        "container": {"name": c},
                    },
                }
                for k in ("app_id", "scope", "type", "ver", "instance",
                          "method", "code", "size", "duration", "useragent"):
                    if k in d:
                        doc[k] = d[k]
                docs.append(doc)

if not docs:
    print("NO DOCS HARVESTED"); sys.exit(1)

bulk = []
for d in docs:
    bulk.append(json.dumps({"create": {}}))
    bulk.append(json.dumps(d))
body = ("\n".join(bulk) + "\n").encode()

req = urllib.request.Request(f"{ES}/{INDEX}/_bulk", data=body,
                             headers={"Content-Type": "application/x-ndjson"}, method="POST")
resp = json.loads(urllib.request.urlopen(req).read())
errs = [i for i in resp.get("items", []) if i.get("create", {}).get("error")]
print(f"harvested={len(docs)} indexed={len(docs)-len(errs)} errors={len(errs)}")
if errs:
    print("first error:", json.dumps(errs[0], indent=2)[:600])
