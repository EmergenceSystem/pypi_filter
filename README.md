# pypi_filter

EmergenceSystem filter that looks up Python packages on PyPI. No API key required.


<!-- emergence-context -->
Part of **[EmergenceSystem](https://github.com/EmergenceSystem)** — a distributed
discovery network of small, single-source agents. This filter joins the em_pop gossip
mesh and answers `POST /agent/query`; Emquest fans each query out to many filters in
parallel and aggregates the results.

## Input

```json
{"query": "requests"}
```

| Field     | Type    | Default | Description              |
|-----------|---------|---------|--------------------------|
| `query`   | string  | —       | Exact package name       |
| `name`    | string  | —       | Alias for `query`        |
| `timeout` | integer | `10`    | HTTP timeout in seconds  |

## Output

One embryo for the matched package:

```json
{
  "properties": {
    "url":      "https://pypi.org/project/requests/",
    "resume":   "Python HTTP for Humans. (v2.31.0)",
    "title":    "requests",
    "version":  "2.31.0",
    "homepage": "https://requests.readthedocs.io",
    "source":   "pypi.org"
  }
}
```

Performs an exact package name lookup via the PyPI JSON API.

## Capabilities

`pypi`, `python`, `packages`, `pip`

## Usage

```bash
rebar3 shell
```

## License

Apache-2.0
