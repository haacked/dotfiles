#!/usr/bin/env bash
case_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${case_dir}/../scaffold.sh" "${case_dir}"
