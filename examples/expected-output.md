# Example: one log line through the pipeline

`sample-input.log` is one line in the CRI log format `tail` reads from
`/var/log/containers/*.log`:

```
2026-01-01T00:00:00.123456789Z stdout F {"level":"info","msg":"order placed","order_id":"ord_123"}
```

Say this line came from `/var/log/containers/checkout-7f8b9_shop_checkout-abc123.log`, where the
`checkout-7f8b9` pod in the `shop` namespace carries the label
`logging.example.com/backend: es`.

1. The `cri` parser splits it into `time`, `stream` (`stdout`), and `message` (the JSON log
   body).
2. The `kubernetes` filter adds `kubernetes.pod_name: checkout-7f8b9`,
   `kubernetes.namespace_name: shop`, and `kubernetes.labels["logging.example.com/backend"]: es`
   from the pod's own metadata.
3. `routing.conf`'s `rewrite_tag` rule matches that label value against `^es$` and rewrites the
   tag to `es.kube.var.log.containers.checkout-7f8b9_shop_checkout-abc123.log`.
4. The `es` OUTPUT's `Match es.kube.*` picks it up and sends it to Elasticsearch, with the
   `kubernetes.*` fields attached alongside the original message.

If that pod had no `logging.example.com/backend` label at all, or the label were set to
something other than `es`/`s3`/`splunk`, the tag would never get rewritten - the record would
keep its original `kube.*` tag and land on the default `stdout` OUTPUT instead, visibly, rather
than being silently dropped. `tests/fixtures/input.jsonl` exercises exactly this case (and the
other two backends) end to end - see `tests/run.sh`.
