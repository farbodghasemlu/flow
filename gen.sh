#!/usr/bin/env bash
set -euo pipefail

cmd_name="${FLOW_CMD_NAME:-$(basename "$0")}"

usage() {
  cat <<USAGE
Diagram generator: emit a directory diagram or a flowchart from entries or a flow spec in Mermaid or Graphviz DOT.

Usage:
  ${cmd_name} [options]

Options:
  -m, --mode MODE         Mode: tree|flow (default: tree)
  --flow                  Shortcut for --mode flow
  -r, --root PATH          Root directory to scan (tree mode, default: .)
  -d, --depth N            Max depth to scan (tree mode, default: 3)
  -f, --format FMT         Output format: mermaid|dot (default: mermaid)
  -o, --out FILE           Write output to FILE (default: stdout)
  --render FMT             Render output with mmdc/dot (png|svg|pdf)
  --render-out FILE        Rendered output file path
  --render-only            Skip raw output; only render
  --dirs-only              Include only directories (tree mode)
  --files-only             Include only files (tree mode)
  --include REGEX          Include paths matching REGEX (tree mode, full path)
  --exclude REGEX          Exclude paths matching REGEX (tree mode, full path)
  --no-default-excludes    Disable built-in excludes (tree mode)
  --title TITLE            Diagram title (Mermaid comment or DOT label)
  --entry TEXT             Flow entry (repeatable, flow mode)
  --entries CSV            Flow entries comma-separated (flow mode)
  --entries-file FILE      Flow entries, one per line (flow mode)
  --flow-spec TEXT         Flow spec line (repeatable, flow mode)
  --flow-file FILE         Flow spec file (flow mode)
  --prompt-entries         Prompt for flow lines (TTY only)
  --prompt-flow            Alias for --prompt-entries
  -h, --help               Show help

Defaults (tree mode):
  Built-in excludes: (^|/)(\.git|node_modules|dist|build|\.next|\.cache)(/|$)

Examples:
  ./flow -r .. -d 2 -f mermaid -o diagram.mmd
  ./flow --format dot --exclude '(^|/)(dist|build)(/|$)' > graph.dot
  ./flow --flow --entries "Start,Validate,Process,Done" -o flow.mmd
  printf "A -> B\nB -> C\n" | ./flow --flow -f dot > flow.dot
USAGE
}

root="."
depth=3
format="mermaid"
out_file=""
dirs_only=0
files_only=0
include_regex=""
exclude_regex=""
use_default_excludes=1
title=""
mode="tree"
entries=()
entries_arg=""
entries_file=""
flow_spec_lines=()
flow_spec_files=()
prompt_entries=0
render_format=""
render_out=""
render_only=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode)
      mode="$2"; shift 2 ;;
    --flow)
      mode="flow"; shift ;;
    -r|--root)
      root="$2"; shift 2 ;;
    -d|--depth)
      depth="$2"; shift 2 ;;
    -f|--format)
      format="$2"; shift 2 ;;
    -o|--out)
      out_file="$2"; shift 2 ;;
    --render)
      render_format="$2"; shift 2 ;;
    --render-out)
      render_out="$2"; shift 2 ;;
    --render-only)
      render_only=1; shift ;;
    --dirs-only)
      dirs_only=1; shift ;;
    --files-only)
      files_only=1; shift ;;
    --include)
      include_regex="$2"; shift 2 ;;
    --exclude)
      exclude_regex="$2"; shift 2 ;;
    --no-default-excludes)
      use_default_excludes=0; shift ;;
    --title)
      title="$2"; shift 2 ;;
    --entry)
      entries+=("$2"); shift 2 ;;
    --entries)
      entries_arg="$2"; shift 2 ;;
    --entries-file)
      entries_file="$2"; shift 2 ;;
    --flow-spec)
      flow_spec_lines+=("$2"); shift 2 ;;
    --flow-file)
      flow_spec_files+=("$2"); shift 2 ;;
    --prompt-entries|--prompt-flow)
      prompt_entries=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

case "$mode" in
  tree|flow) ;;
  *)
    echo "Unsupported mode: $mode" >&2
    exit 1
    ;;
 esac

case "$format" in
  mermaid|dot) ;;
  *)
    echo "Unsupported format: $format" >&2
    exit 1
    ;;
 esac

if [[ "$render_only" -eq 1 && -z "$render_format" ]]; then
  echo "--render-only requires --render FMT." >&2
  exit 1
fi

if [[ -n "$render_out" && -z "$render_format" ]]; then
  echo "--render-out requires --render FMT." >&2
  exit 1
fi

if [[ -n "$render_format" ]]; then
  if ! [[ "$render_format" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "Invalid render format: $render_format" >&2
    exit 1
  fi
  if [[ "$format" == "mermaid" ]]; then
    case "$render_format" in
      png|svg|pdf) ;;
      *)
        echo "Mermaid render format must be png, svg, or pdf." >&2
        exit 1
        ;;
    esac
  fi
fi

escape_label() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  printf '%s' "$s"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_valid_node_id() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

add_lines_from_string() {
  local s="$1"
  while IFS= read -r line; do
    flow_input_lines+=("$line")
  done <<< "$s"
}

split_targets() {
  local s="$1"
  local buf=""
  local depth_square=0
  local depth_curly=0
  local depth_paren=0
  targets=()
  local i ch
  for ((i=0; i<${#s}; i++)); do
    ch="${s:$i:1}"
    case "$ch" in
      '[') depth_square=$((depth_square + 1)) ;;
      ']') depth_square=$((depth_square - 1)) ;;
      '{') depth_curly=$((depth_curly + 1)) ;;
      '}') depth_curly=$((depth_curly - 1)) ;;
      '(') depth_paren=$((depth_paren + 1)) ;;
      ')') depth_paren=$((depth_paren - 1)) ;;
      ',')
        if [[ "$depth_square" -eq 0 && "$depth_curly" -eq 0 && "$depth_paren" -eq 0 ]]; then
          targets+=("$(trim "$buf")")
          buf=""
          continue
        fi
        ;;
    esac
    buf+="$ch"
  done
  if [[ -n "$buf" ]]; then
    targets+=("$(trim "$buf")")
  fi
}

derive_render_out() {
  if [[ -n "$render_out" ]]; then
    printf '%s' "$render_out"
    return
  fi

  local base=""
  if [[ -n "${render_base_file:-}" ]]; then
    base="$render_base_file"
  else
    base="diagram"
  fi
  base="${base%.*}"
  printf '%s.%s' "$base" "$render_format"
}

prompt_flow_lines() {
  echo "Enter flow lines (edges like 'A -> B', or entries one per line). Blank line to finish:" >&2
  while IFS= read -r line; do
    line="$(trim "$line")"
    if [[ -z "$line" ]]; then
      break
    fi
    flow_input_lines+=("$line")
  done
}

read_stdin_lines() {
  while IFS= read -r line || [[ -n "$line" ]]; do
    flow_input_lines+=("$line")
  done
}

parse_node_expr() {
  local expr="$1"
  expr="$(trim "$expr")"
  local id=""
  local label=""
  local shape=""

  if [[ "$expr" =~ ^([A-Za-z0-9_.-]+)\(\((.*)\)\)$ ]]; then
    id="${BASH_REMATCH[1]}"
    label="${BASH_REMATCH[2]}"
    shape="circle"
  elif [[ "$expr" =~ ^([A-Za-z0-9_.-]+)\(\[(.*)\]\)$ ]]; then
    id="${BASH_REMATCH[1]}"
    label="${BASH_REMATCH[2]}"
    shape="stadium"
  elif [[ "$expr" =~ ^([A-Za-z0-9_.-]+)\{(.*)\}$ ]]; then
    id="${BASH_REMATCH[1]}"
    label="${BASH_REMATCH[2]}"
    shape="diamond"
  elif [[ "$expr" =~ ^([A-Za-z0-9_.-]+)\[(.*)\]$ ]]; then
    id="${BASH_REMATCH[1]}"
    label="${BASH_REMATCH[2]}"
    shape="box"
  else
    id="$expr"
    label=""
    shape=""
  fi

  label="$(trim "$label")"
  printf '%s\037%s\037%s' "$id" "$label" "$shape"
}

register_node() {
  local id="$1"
  local label="$2"
  local shape="$3"

  if [[ -z "$id" ]]; then
    echo "Invalid node id in flow spec." >&2
    exit 1
  fi
  if ! is_valid_node_id "$id"; then
    echo "Invalid node id '$id'. Use a simple id and put the display text in brackets, e.g. id[Label]." >&2
    exit 1
  fi

  if [[ -z ${flow_label_map[$id]+x} ]]; then
    flow_node_ids+=("$id")
    flow_label_map["$id"]="$id"
    flow_shape_map["$id"]="box"
  fi

  if [[ -n "$label" ]]; then
    flow_label_map["$id"]="$label"
  fi
  if [[ -n "$shape" ]]; then
    flow_shape_map["$id"]="$shape"
  fi
}

write_mermaid_flow() {
  local out
  out="graph TD\n"
  if [[ -n "$title" ]]; then
    out+="%% $title\n"
  fi
  out+="classDef step fill:#E8F5E9,stroke:#2E7D32,stroke-width:1px;\n"

  for node_id in "${flow_node_ids[@]}"; do
    local internal_id="${flow_id_map[$node_id]}"
    local label="$(escape_label "${flow_label_map[$node_id]}")"
    local shape="${flow_shape_map[$node_id]}"
    local node_line
    case "$shape" in
      diamond)
        node_line="${internal_id}{${label}}" ;;
      circle)
        node_line="${internal_id}((${label}))" ;;
      stadium)
        node_line="${internal_id}([${label}])" ;;
      box|*)
        node_line="${internal_id}[\"${label}\"]" ;;
    esac
    out+="  ${node_line}:::step\n"
  done

  for i in "${!edge_from[@]}"; do
    local from_id="${flow_id_map[${edge_from[$i]}]}"
    local to_id="${flow_id_map[${edge_to[$i]}]}"
    local edge_lbl="${edge_label[$i]}"
    if [[ -n "$edge_lbl" ]]; then
      edge_lbl="$(escape_label "$edge_lbl")"
      out+="  ${from_id} -->|${edge_lbl}| ${to_id}\n"
    else
      out+="  ${from_id} --> ${to_id}\n"
    fi
  done

  printf '%b' "$out"
}

write_dot_flow() {
  local out
  out="digraph G {\n"
  out+="  graph [rankdir=TB];\n"
  out+="  node [shape=box];\n"
  if [[ -n "$title" ]]; then
    out+="  label=\"$(escape_label "$title")\";\n"
    out+="  labelloc=top;\n"
  fi

  for node_id in "${flow_node_ids[@]}"; do
    local internal_id="${flow_id_map[$node_id]}"
    local label="$(escape_label "${flow_label_map[$node_id]}")"
    local shape="${flow_shape_map[$node_id]}"
    local shape_attr="box"
    local style_attr="filled"
    case "$shape" in
      diamond)
        shape_attr="diamond" ;;
      circle)
        shape_attr="circle" ;;
      stadium)
        shape_attr="box"
        style_attr="rounded,filled" ;;
      box|*)
        shape_attr="box" ;;
    esac
    out+="  ${internal_id} [label=\"${label}\", shape=${shape_attr}, style=\"${style_attr}\", fillcolor=\"#E8F5E9\"];\n"
  done

  for i in "${!edge_from[@]}"; do
    local from_id="${flow_id_map[${edge_from[$i]}]}"
    local to_id="${flow_id_map[${edge_to[$i]}]}"
    local edge_lbl="${edge_label[$i]}"
    if [[ -n "$edge_lbl" ]]; then
      edge_lbl="$(escape_label "$edge_lbl")"
      out+="  ${from_id} -> ${to_id} [label=\"${edge_lbl}\"];\n"
    else
      out+="  ${from_id} -> ${to_id};\n"
    fi
  done

  out+="}\n"
  printf '%b' "$out"
}

output=""

if [[ "$mode" == "flow" ]]; then
  entries_sources=0
  spec_sources=0
  if [[ ${#entries[@]} -gt 0 || -n "$entries_arg" || -n "$entries_file" ]]; then
    entries_sources=1
  fi
  if [[ ${#flow_spec_lines[@]} -gt 0 || ${#flow_spec_files[@]} -gt 0 ]]; then
    spec_sources=1
  fi

  if [[ "$entries_sources" -eq 1 && "$spec_sources" -eq 1 ]]; then
    echo "Cannot mix entry-based flow inputs with flow spec inputs." >&2
    exit 1
  fi

  declare -A flow_label_map
  declare -A flow_shape_map
  flow_node_ids=()
  edge_from=()
  edge_to=()
  edge_label=()

  if [[ "$entries_sources" -eq 1 ]]; then
    flow_entries=()

    if [[ ${#entries[@]} -gt 0 ]]; then
      flow_entries+=("${entries[@]}")
    fi

    if [[ -n "$entries_arg" ]]; then
      IFS=',' read -r -a parsed_entries <<< "$entries_arg"
      for e in "${parsed_entries[@]}"; do
        e="$(trim "$e")"
        if [[ -n "$e" ]]; then
          flow_entries+=("$e")
        fi
      done
    fi

    if [[ -n "$entries_file" ]]; then
      if [[ ! -f "$entries_file" ]]; then
        echo "Entries file not found: $entries_file" >&2
        exit 1
      fi
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(trim "$line")"
        if [[ -n "$line" ]]; then
          flow_entries+=("$line")
        fi
      done < "$entries_file"
    fi

    if [[ ${#flow_entries[@]} -eq 0 ]]; then
      echo "No entries provided for flowchart." >&2
      exit 1
    fi

    for i in "${!flow_entries[@]}"; do
      node_id="step${i}"
      flow_node_ids+=("$node_id")
      flow_label_map["$node_id"]="${flow_entries[$i]}"
      flow_shape_map["$node_id"]="box"
      if [[ "$i" -gt 0 ]]; then
        edge_from+=("step$((i - 1))")
        edge_to+=("$node_id")
        edge_label+=("")
      fi
    done
  else
    flow_input_lines=()

    if [[ ${#flow_spec_lines[@]} -gt 0 ]]; then
      for spec in "${flow_spec_lines[@]}"; do
        add_lines_from_string "$spec"
      done
    fi

    if [[ ${#flow_spec_files[@]} -gt 0 ]]; then
      for file in "${flow_spec_files[@]}"; do
        if [[ ! -f "$file" ]]; then
          echo "Flow spec file not found: $file" >&2
          exit 1
        fi
        while IFS= read -r line || [[ -n "$line" ]]; do
          flow_input_lines+=("$line")
        done < "$file"
      done
    fi

    if [[ "$prompt_entries" -eq 1 ]]; then
      if [[ ! -t 0 ]]; then
        echo "Cannot prompt for entries: stdin is not a TTY." >&2
        exit 1
      fi
      prompt_flow_lines
    elif [[ ${#flow_input_lines[@]} -eq 0 ]]; then
      if [[ -t 0 ]]; then
        prompt_flow_lines
      else
        read_stdin_lines
      fi
    fi

    if [[ ${#flow_input_lines[@]} -eq 0 ]]; then
      echo "No flow input provided." >&2
      exit 1
    fi

    has_edges=0
    for line in "${flow_input_lines[@]}"; do
      if [[ "$line" == *"->"* ]]; then
        has_edges=1
        break
      fi
    done

    if [[ "$has_edges" -eq 0 ]]; then
      flow_entries=()
      for line in "${flow_input_lines[@]}"; do
        line="$(trim "$line")"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        flow_entries+=("$line")
      done

      if [[ ${#flow_entries[@]} -eq 0 ]]; then
        echo "No entries provided for flowchart." >&2
        exit 1
      fi

      for i in "${!flow_entries[@]}"; do
        node_id="step${i}"
        flow_node_ids+=("$node_id")
        flow_label_map["$node_id"]="${flow_entries[$i]}"
        flow_shape_map["$node_id"]="box"
        if [[ "$i" -gt 0 ]]; then
          edge_from+=("step$((i - 1))")
          edge_to+=("$node_id")
          edge_label+=("")
        fi
      done
    else
      for line in "${flow_input_lines[@]}"; do
        line="$(trim "$line")"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        if [[ "$line" == *"->"* ]]; then
          left="${line%%->*}"
          right="${line#*->}"
          left="$(trim "$left")"
          right="$(trim "$right")"

          edge_lbl=""
          if [[ "$right" == *"|"* ]]; then
            edge_lbl="${right#*|}"
            right="${right%%|*}"
            edge_lbl="$(trim "$edge_lbl")"
          fi

          if [[ -z "$left" || -z "$right" ]]; then
            echo "Invalid edge line: $line" >&2
            exit 1
          fi

          split_targets "$right"
          dests=("${targets[@]}")

          parsed_left="$(parse_node_expr "$left")"
          IFS=$'\037' read -r from_id from_label from_shape <<< "$parsed_left"
          register_node "$from_id" "$from_label" "$from_shape"

          for dest in "${dests[@]}"; do
            dest="$(trim "$dest")"
            [[ -z "$dest" ]] && continue
            parsed_dest="$(parse_node_expr "$dest")"
            IFS=$'\037' read -r to_id to_label to_shape <<< "$parsed_dest"
            register_node "$to_id" "$to_label" "$to_shape"
            edge_from+=("$from_id")
            edge_to+=("$to_id")
            edge_label+=("$edge_lbl")
          done
        else
          if [[ "$line" =~ ^([A-Za-z0-9_.-]+)[[:space:]]*:[[:space:]]*(.+)$ ]]; then
            node_id="${BASH_REMATCH[1]}"
            node_label="${BASH_REMATCH[2]}"
            register_node "$node_id" "$node_label" "box"
          else
            parsed_node="$(parse_node_expr "$line")"
            IFS=$'\037' read -r node_id node_label node_shape <<< "$parsed_node"
            register_node "$node_id" "$node_label" "$node_shape"
          fi
        fi
      done

      if [[ ${#flow_node_ids[@]} -eq 0 ]]; then
        echo "No nodes parsed from flow spec." >&2
        exit 1
      fi
    fi
  fi

  declare -A flow_id_map
  for i in "${!flow_node_ids[@]}"; do
    flow_id_map["${flow_node_ids[$i]}"]="f$i"
  done

  case "$format" in
    mermaid)
      output="$(write_mermaid_flow)" ;;
    dot)
      output="$(write_dot_flow)" ;;
  esac
else
  if [[ "$dirs_only" -eq 1 && "$files_only" -eq 1 ]]; then
    echo "--dirs-only and --files-only cannot be used together." >&2
    exit 1
  fi

  if [[ ! -d "$root" ]]; then
    echo "Root is not a directory: $root" >&2
    exit 1
  fi

  if ! [[ "$depth" =~ ^[0-9]+$ ]]; then
    echo "Depth must be a non-negative integer." >&2
    exit 1
  fi

  root_abs="$(cd "$root" && pwd)"
  root_label="$(basename "$root_abs")"
  if [[ -z "$root_label" || "$root_label" == "/" ]]; then
    root_label="/"
  fi

  # Compose default exclude regex unless disabled.
  default_exclude="(^|/)(\.git|node_modules|dist|build|\.next|\.cache)(/|$)"
  if [[ "$use_default_excludes" -eq 1 ]]; then
    if [[ -n "$exclude_regex" ]]; then
      exclude_regex="($exclude_regex)|($default_exclude)"
    else
      exclude_regex="$default_exclude"
    fi
  fi

  # Collect paths
  paths=()
  while IFS= read -r -d '' p; do
    paths+=("$p")
  done < <(find "$root_abs" -mindepth 0 -maxdepth "$depth" \( -type d -o -type f \) -print0)

  # Sort for stable output (GNU sort -z expected)
  if sort -z </dev/null >/dev/null 2>&1; then
    sorted_paths=()
    while IFS= read -r -d '' p; do
      sorted_paths+=("$p")
    done < <(printf '%s\0' "${paths[@]}" | sort -z)
    paths=("${sorted_paths[@]}")
  fi

  declare -A include_map
  declare -A is_dir_map

  # Determine inclusion
  for p in "${paths[@]}"; do
    if [[ "$p" == "$root_abs" ]]; then
      include_map["$p"]=1
    else
      if [[ "$dirs_only" -eq 1 && ! -d "$p" ]]; then
        continue
      fi
      if [[ "$files_only" -eq 1 && -d "$p" ]]; then
        continue
      fi
      if [[ -n "$include_regex" && ! "$p" =~ $include_regex ]]; then
        continue
      fi
      if [[ -n "$exclude_regex" && "$p" =~ $exclude_regex ]]; then
        continue
      fi
      include_map["$p"]=1
    fi
    if [[ -d "$p" ]]; then
      is_dir_map["$p"]=1
    fi
   done

  # Assign ids
  id_counter=0
  declare -A id_map
  for p in "${paths[@]}"; do
    if [[ -n ${include_map[$p]+x} ]]; then
      id_map["$p"]="n${id_counter}"
      id_counter=$((id_counter + 1))
    fi
   done

  # Build edges
  edges=()
  for p in "${paths[@]}"; do
    if [[ -z ${include_map[$p]+x} ]]; then
      continue
    fi
    if [[ "$p" == "$root_abs" ]]; then
      continue
    fi
    parent="$(dirname "$p")"
    if [[ -n ${id_map[$parent]+x} ]]; then
      edges+=("${id_map[$parent]} ${id_map[$p]}")
    fi
   done

  write_mermaid() {
    local out
    out="graph TD\n"
    if [[ -n "$title" ]]; then
      out+="%% $title\n"
    fi
    out+="classDef dir fill:#E3F2FD,stroke:#1976D2,stroke-width:1px;\n"
    out+="classDef file fill:#FFF3E0,stroke:#F57C00,stroke-width:1px;\n"

    for p in "${paths[@]}"; do
      if [[ -z ${id_map[$p]+x} ]]; then
        continue
      fi
      local label
      if [[ "$p" == "$root_abs" ]]; then
        label="$root_label"
      else
        label="${p#"$root_abs"/}"
      fi
      label="$(escape_label "$label")"
      if [[ -n ${is_dir_map[$p]+x} ]]; then
        out+="  ${id_map[$p]}[\"$label\"]:::dir\n"
      else
        out+="  ${id_map[$p]}[\"$label\"]:::file\n"
      fi
    done

    for e in "${edges[@]}"; do
      out+="  ${e% *} --> ${e#* }\n"
    done

    printf '%b' "$out"
  }

  write_dot() {
    local out
    out="digraph G {\n"
    out+="  graph [rankdir=TB];\n"
    out+="  node [shape=box];\n"
    if [[ -n "$title" ]]; then
      out+="  label=\"$(escape_label "$title")\";\n"
      out+="  labelloc=top;\n"
    fi

    for p in "${paths[@]}"; do
      if [[ -z ${id_map[$p]+x} ]]; then
        continue
      fi
      local label
      if [[ "$p" == "$root_abs" ]]; then
        label="$root_label"
      else
        label="${p#"$root_abs"/}"
      fi
      label="$(escape_label "$label")"
      if [[ -n ${is_dir_map[$p]+x} ]]; then
        out+="  ${id_map[$p]} [label=\"$label\", style=filled, fillcolor=\"#E3F2FD\"];\n"
      else
        out+="  ${id_map[$p]} [label=\"$label\", style=filled, fillcolor=\"#FFF3E0\"];\n"
      fi
    done

    for e in "${edges[@]}"; do
      out+="  ${e% *} -> ${e#* };\n"
    done

    out+="}\n"
    printf '%b' "$out"
  }

  case "$format" in
    mermaid)
      output="$(write_mermaid)" ;;
    dot)
      output="$(write_dot)" ;;
  esac
fi

cleanup_paths=()
cleanup() {
  for p in "${cleanup_paths[@]}"; do
    if [[ -n "$p" && -f "$p" ]]; then
      rm -f "$p"
    fi
  done
}

if [[ -n "$render_format" ]]; then
  trap cleanup EXIT

  spec_out_file="$out_file"
  render_base_file="$out_file"
  if [[ "$render_only" -eq 1 ]]; then
    spec_out_file=""
  fi

  spec_path=""
  if [[ -n "$spec_out_file" ]]; then
    printf '%s' "$output" > "$spec_out_file"
    spec_path="$spec_out_file"
  else
    spec_ext="mmd"
    if [[ "$format" == "dot" ]]; then
      spec_ext="dot"
    fi
    tmp_dir="${TMPDIR:-/tmp}"
    spec_path="$(mktemp "${tmp_dir}/flow.XXXXXX.${spec_ext}")"
    cleanup_paths+=("$spec_path")
    printf '%s' "$output" > "$spec_path"
    if [[ "$render_only" -eq 0 ]]; then
      printf '%s' "$output"
    fi
  fi

  render_path="$(derive_render_out)"
  if [[ "$format" == "mermaid" ]]; then
    if ! command -v mmdc >/dev/null 2>&1; then
      echo "mmdc not found. Install Mermaid CLI to render." >&2
      exit 1
    fi
    mmdc -i "$spec_path" -o "$render_path"
  else
    if ! command -v dot >/dev/null 2>&1; then
      echo "dot not found. Install Graphviz to render." >&2
      exit 1
    fi
    dot -T"$render_format" "$spec_path" -o "$render_path"
  fi
else
  if [[ -n "$out_file" ]]; then
    printf '%s' "$output" > "$out_file"
  else
    printf '%s' "$output"
  fi
fi
