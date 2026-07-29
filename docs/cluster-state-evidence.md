# Cluster State Evidence

Real `kubectl get pods -A -o wide` output, captured after all three
environments, the monitoring stack, and External Secrets Operator were up
and running simultaneously (system namespaces omitted for brevity):

```
NAMESPACE            NAME                                                        READY   STATUS    RESTARTS   AGE
development          api-5466fb6758-h7bfc                                        1/1     Running   0          25m
development          postgres-0                                                  1/1     Running   0          3h
development          worker-9c67598f4-npdjx                                      1/1     Running   0          19m
external-secrets     external-secrets-7576b55f9b-5z2b4                           1/1     Running   0          73m
external-secrets     external-secrets-cert-controller-78cfd7dff8-25fxj           1/1     Running   0          73m
external-secrets     external-secrets-webhook-764bdc4464-vxwhs                   1/1     Running   0          73m
monitoring           alertmanager-kube-prometheus-stack-alertmanager-0           2/2     Running   0          3h7m
monitoring           kube-prometheus-stack-grafana-86dc44c897-9j5fp              3/3     Running   0          135m
monitoring           kube-prometheus-stack-kube-state-metrics-7d948b6c6b-9wj4p   1/1     Running   0          3h8m
monitoring           kube-prometheus-stack-operator-645cf547d-ndjnh              1/1     Running   0          3h8m
monitoring           kube-prometheus-stack-prometheus-node-exporter-9xgcn        1/1     Running   0          3h8m
monitoring           loki-stack-0                                                1/1     Running   0          3h6m
monitoring           loki-stack-promtail-tdqsg                                   1/1     Running   0          3h6m
monitoring           prometheus-kube-prometheus-stack-prometheus-0               2/2     Running   0          3h7m
production           api-6979795bc4-bnnzv                                        1/1     Running   0          67m
production           api-6979795bc4-dl7tw                                        1/1     Running   0          66m
production           api-6979795bc4-ldmvq                                        1/1     Running   0          66m
production           postgres-0                                                  1/1     Running   0          3h
production           worker-7b6f8474c9-5mrw7                                     1/1     Running   0          66m
production           worker-7b6f8474c9-6bqmk                                     1/1     Running   0          67m
staging              api-66b86c9f94-kdxrb                                        1/1     Running   0          66m
staging              api-66b86c9f94-mgbpx                                        1/1     Running   0          67m
staging              postgres-0                                                  1/1     Running   0          3h
staging              worker-847f96b84d-pjjbk                                     1/1     Running   0          67m
```

Notes on what this confirms:
- **Correct replica counts per environment**: development has 1 `api`/1
  `worker`, staging has 2 `api`/1 `worker`, production has 3 `api`/2
  `worker` - exactly matching the environment differences table in
  `README.md`, driven entirely by the Kustomize overlay patches.
- **Zero restarts** across every pod at time of capture - no
  crash-looping, no OOMKills, despite the intentionally tight resource
  budget documented in `docs/cost-analysis.md`'s utilization section.
- **Every one of Prometheus, Grafana, Alertmanager, Loki, Promtail,
  kube-state-metrics, and External Secrets Operator's three components**
  running healthy alongside all three application environments
  simultaneously, on a single-node cluster with a 5GB/4-CPU budget.

`kubectl top nodes` at the same point in time:
```
NAME                            CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
advanced-devops-control-plane   393m         9%       3096Mi          63%
```
