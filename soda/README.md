# Custom Trino quality monitor

This is a Python monitor. It runs SQL against the Iceberg catalog through Trino's HTTP statement API. One-shot validation exits nonzero on query errors or failed checks:

```bash
python data_quality_monitor.py --once
```

Docker Compose runs periodic scans. See the root README for checks and environment variables.
