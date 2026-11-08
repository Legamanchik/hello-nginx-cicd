import json, pathlib

PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
S1 = "https://51-21-5-62.sslip.io/healthz"
S2 = "https://51-20-48-179.sslip.io/healthz"
panels, pid = [], 0

def add(title, ptype, x, y, w, h, targets, ds=PROM, **extra):
    global pid
    pid += 1
    panels.append({"id": pid, "title": title, "type": ptype, "datasource": ds,
                   "gridPos": {"x": x, "y": y, "w": w, "h": h},
                   "targets": [dict(t, refId=chr(65 + i), datasource=ds) for i, t in enumerate(targets)],
                   **extra})

updown = {"defaults": {"mappings": [{"type": "value", "options": {
            "0": {"text": "DOWN", "color": "red"}, "1": {"text": "UP", "color": "green"}}}],
          "color": {"mode": "thresholds"},
          "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]}}}
stat_opts = {"colorMode": "background", "graphMode": "none", "textMode": "value",
             "reduceOptions": {"calcs": ["lastNotNull"]}}

add("Server 1 (Docker)", "stat", 0, 0, 6, 4,
    [{"expr": f'probe_success{{instance="{S1}"}}'}], fieldConfig=updown, options=stat_opts)
add("Server 2 (Kubernetes)", "stat", 6, 0, 6, 4,
    [{"expr": f'probe_success{{instance="{S2}"}}'}], fieldConfig=updown, options=stat_opts)
add("Ready pods", "stat", 12, 0, 6, 4,
    [{"expr": 'sum(kube_deployment_status_replicas_available{namespace="hello",deployment="hello-nginx"})'}],
    fieldConfig={"defaults": {"thresholds": {"mode": "absolute", "steps": [
        {"color": "red", "value": None}, {"color": "orange", "value": 1}, {"color": "green", "value": 2}]}}},
    options=stat_opts)
add("Firing alerts", "stat", 18, 0, 6, 4,
    [{"expr": 'count(ALERTS{alertstate="firing",alertname=~"HelloNginx.*"}) or vector(0)'}],
    fieldConfig={"defaults": {"thresholds": {"mode": "absolute", "steps": [
        {"color": "green", "value": None}, {"color": "red", "value": 1}]}}},
    options=stat_opts)

add("TLS certificate expires in", "stat", 0, 4, 6, 8,
    [{"expr": 'min by (instance) (probe_ssl_earliest_cert_expiry{job="hello-nginx-probe"} - time())',
      "legendFormat": "{{instance}}"}],
    fieldConfig={"defaults": {"unit": "s", "thresholds": {"mode": "absolute", "steps": [
        {"color": "red", "value": None}, {"color": "orange", "value": 1209600}, {"color": "green", "value": 2592000}]}}},
    options=dict(stat_opts, textMode="value_and_name"))
add("Response time", "timeseries", 6, 4, 6, 8,
    [{"expr": f'probe_duration_seconds{{instance="{S1}"}}', "legendFormat": "Server 1"},
     {"expr": f'probe_duration_seconds{{instance="{S2}"}}', "legendFormat": "Server 2"}],
    fieldConfig={"defaults": {"unit": "s"}})
add("Requests per second (Kubernetes)", "timeseries", 12, 4, 12, 8,
    [{"expr": 'sum(rate(nginx_http_requests_total{namespace="hello"}[2m]))', "legendFormat": "req/s"}],
    fieldConfig={"defaults": {"unit": "reqps"}})

add("Active connections", "timeseries", 0, 12, 8, 7,
    [{"expr": 'sum(nginx_connections_active{namespace="hello"})', "legendFormat": "active"}])
add("Memory by pod", "timeseries", 8, 12, 8, 7,
    [{"expr": 'sum by (pod) (container_memory_working_set_bytes{namespace="hello",container!=""})',
      "legendFormat": "{{pod}}"}],
    fieldConfig={"defaults": {"unit": "bytes"}})
add("HTTP status codes (from access logs)", "timeseries", 16, 12, 8, 7,
    [{"expr": 'sum by (status) (count_over_time({namespace="hello", container="nginx"} '
              '| pattern `<_> - <_> [<_>] "<_> <_> <_>" <status> <_>` | status != "" [1m]))',
      "legendFormat": "{{status}}"}], ds=LOKI)

add("Logs", "logs", 0, 19, 24, 10,
    [{"expr": '{namespace="hello", container="nginx"}'}], ds=LOKI,
    options={"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending"})

dashboard = {"uid": "hello-nginx", "title": "Hello Nginx", "tags": ["hello-nginx"],
             "timezone": "browser", "refresh": "30s", "schemaVersion": 39,
             "time": {"from": "now-1h", "to": "now"}, "panels": panels}
out = pathlib.Path(__file__).with_name("hello-nginx.json")
out.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {out} ({len(panels)} panels)")
