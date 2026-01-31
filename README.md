# Diagram Generator (Bash)

A Bash tool that can scan a directory tree or take flow inputs (entries or a flow spec) and emit a diagram in Mermaid or Graphviz DOT format. It also supports optional rendering via Mermaid CLI (`mmdc`) or Graphviz `dot`.

## Features

- Mermaid (`graph TD`) or Graphviz DOT (`digraph`) output
- Tree mode: depth-limited traversal, include/exclude filters, files-only or dirs-only
- Flow mode: entry lists or a flow spec with branching, shapes, and labels
- Optional rendering to `png`/`svg`/`pdf` via `mmdc`/`dot`
- Stable output ordering for tree mode (sorted paths)
- Built-in default excludes for common heavy folders

## Requirements

- Bash 4+ (associative arrays)
- `find` and `sort` (GNU `sort` supports `-z` for stable null-delimited sorting)

Optional (only if you use `--render`):

- `mmdc` (Mermaid CLI) for Mermaid rendering
- `dot` (Graphviz) for DOT rendering

## Usage

```bash
flow [options]
```

Notes:

- `flow` is the executable entrypoint.
- `gen.sh` is the implementation script (you can run it directly if you prefer).

### Add to PATH

To run `flow` from anywhere, add `/home/user/diagram-gen` to your PATH.

For bash:

```bash
echo 'export PATH="$PATH:/home/user/diagram-gen"' >> ~/.bashrc
source ~/.bashrc
```

For zsh:

```bash
echo 'export PATH="$PATH:/home/user/diagram-gen"' >> ~/.zshrc
source ~/.zshrc
```

### Modes

- `tree` (default): build a diagram from a directory tree
- `flow`: build a flowchart from entries or a flow spec

### Options

Common:

- `-m, --mode MODE`:
  Mode: `tree` or `flow` (default: `tree`)
- `--flow`:
  Shortcut for `--mode flow`
- `-f, --format FMT`:
  Output format: `mermaid` or `dot` (default: `mermaid`)
- `-o, --out FILE`:
  Write output to FILE (default: stdout)
- `--render FMT`:
  Render output using `mmdc`/`dot` (e.g., `png`, `svg`, `pdf`)
- `--render-out FILE`:
  Rendered output file path
- `--render-only`:
  Skip raw output; only render
- `--title TITLE`:
  Diagram title (Mermaid comment or DOT graph label)
- `-h, --help`:
  Show help

Tree mode:

- `-r, --root PATH`:
  Root directory to scan (default: `.`)
- `-d, --depth N`:
  Max depth to scan (default: `3`)
- `--dirs-only`:
  Include only directories
- `--files-only`:
  Include only files
- `--include REGEX`:
  Include paths matching REGEX (applies to full path)
- `--exclude REGEX`:
  Exclude paths matching REGEX (applies to full path)
- `--no-default-excludes`:
  Disable built-in excludes

Flow mode:

- `--entry TEXT`:
  Add a single entry (repeatable)
- `--entries CSV`:
  Entries as a comma-separated list
- `--entries-file FILE`:
  Entries from a file, one per line
- `--flow-spec TEXT`:
  Flow spec line (repeatable)
- `--flow-file FILE`:
  Flow spec file (lines with edges or node definitions)
- `--prompt-entries`:
  Prompt for flow lines (TTY only)
- `--prompt-flow`:
  Alias for `--prompt-entries`

### Flow spec syntax

Flow spec lines let you create branching flowcharts. If any input line contains `->`, the script treats the input as a flow spec.

Edges:

- `from -> to` creates an edge
- `from -> to1, to2` creates multiple edges
- `from -> to | LABEL` adds an edge label

Node definitions and shapes:

- `id[Label]` box (default)
- `id{Label}` diamond (decision)
- `id((Label))` circle
- `id([Label])` stadium (rounded)
- `id: Label` box

Notes:

- Lines starting with `#` are ignored as comments.
- Node IDs should be simple: letters, numbers, `_`, `-`, `.` (no spaces). Put the display text in brackets.
- The `|` character is reserved for edge labels.

### Default Excludes (tree mode)

Unless `--no-default-excludes` is set, the script automatically excludes these paths:

```
(^|/)(\.git|node_modules|dist|build|\.next|\.cache)(/|$)
```

If you pass `--exclude`, it is combined with the defaults.

## Examples

### Tree mode

Generate a Mermaid diagram for the parent directory with depth 2:

```bash
flow -r .. -d 2 -f mermaid -o diagram.mmd
```

Generate a DOT diagram and exclude build output:

```bash
flow --format dot --exclude '(^|/)(dist|build)(/|$)' > graph.dot
```

Render a PNG directly from a tree scan:

```bash
flow -r .. -d 2 -f mermaid --render png --render-out tree.png --render-only
```

### Flow mode (entries)

From a comma-separated list:

```bash
flow --flow --entries "Draft,Review,Publish" -o flow.mmd
```

From repeated `--entry` flags (useful if entries contain commas):

```bash
flow --flow --entry "Start" --entry "Verify, Approve" --entry "Complete"
```

From a file (one entry per line):

```bash
flow --flow --entries-file steps.txt -f dot > flow.dot
```

From stdin (one entry per line):

```bash
printf "Start\nCheck\nEnd\n" | flow --mode flow --format dot > flow.dot
```

Interactive prompt (blank line to finish):

```bash
flow --flow
```

### Flow mode (flow spec)

Example 1 (simple review pipeline):

```bash
cat <<'EOF' > flow1.txt
idea[Idea submitted] -> review{Review complete?}
review -> accept[Accepted] | YES
review -> revise[Needs changes] | NO
revise -> idea
accept -> publish[Published]
EOF

flow --flow --flow-file flow1.txt -o flow1.mmd
```

Example 2 (order processing with a decision):

```bash
cat <<'EOF' > flow2.txt
order[Order received] -> stock{In stock?}
stock -> pack[Pack item] | YES
stock -> notify[Notify customer] | NO
pack -> ship[Ship order]
notify -> end[Close request]
EOF

flow --flow --flow-file flow2.txt -o flow2.mmd
```

## Notes

- Tree mode labels are derived from paths relative to the root directory.
- Flow mode connects entries in the order they are provided when using entry lists.
- Flow spec mode supports branching, node shapes, and optional edge labels.
- Mermaid nodes are styled with simple colors for directories vs files.
- DOT output adds `label` to the graph when `--title` is provided.
- If `sort -z` is not available, tree output order follows `find` order.

## Rendering

Use `--render` to invoke `mmdc` (for Mermaid) or `dot` (for Graphviz) directly from the script. If you omit `--render-out`, the output name is derived from `-o` (or defaults to `diagram.<fmt>`).

### Mermaid

```bash
flow --flow --entries "Start,Check,End" --render svg --render-out flow.svg --render-only
```

### Graphviz DOT

```bash
flow --flow --entries "Start,Check,End" -f dot --render png --render-out flow.png --render-only
```
