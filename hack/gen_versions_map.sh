#!/bin/sh
set -e

file=versions_map

charts=$(find . -mindepth 2 -maxdepth 2 -name Chart.yaml | awk 'sub("/Chart.yaml", "")')

new_map=$(
  for chart in $charts; do
    awk '/^name:/ {chart=$2} /^version:/ {version=$2} END{printf "%s %s %s\n", chart, version, "HEAD"}' "$chart/Chart.yaml"
  done
)

if [ ! -f "$file" ] || [ ! -s "$file" ]; then
  echo "$new_map" > "$file"
  exit 0
fi

miss_map=$(mktemp)
trap 'rm -f "$miss_map"' EXIT
echo -n "$new_map" | awk 'NR==FNR { nm[$1 " " $2] = $3; next } { if (!($1 " " $2 in nm)) print $1, $2, $3}' - "$file" > $miss_map

# search accross all tags sorted by version
search_commits=$(git ls-remote --tags origin | awk -F/ '$3 ~ /v[0-9]+.[0-9]+.[0-9]+/ {print}' | sort -k2,2 -rV | awk '{print $1}')

resolved_miss_map=$(
  while read -r chart version commit; do
    # if version is found in HEAD, it's HEAD
    if [ "$(awk '$1 == "version:" {print $2}' ./${chart}/Chart.yaml)" = "${version}" ]; then
      echo "$chart $version HEAD"
      continue
    fi

    # if commit is not HEAD, check if it's valid
    if [ "$commit" != "HEAD" ]; then
      if [ "$(git show "${commit}:./${chart}/Chart.yaml" | awk '$1 == "version:" {print $2}')" != "${version}" ]; then
        echo "Commit $commit for $chart $version is not valid" >&2
        exit 1
      fi

      commit=$(git rev-parse --short "$commit")
      echo "$chart $version $commit"
      continue
    fi

    # if commit is HEAD, but version is not found in HEAD, check all tags
    found_tag=""
    for tag in $search_commits; do
      if [ "$(git show "${tag}:./${chart}/Chart.yaml" | awk '$1 == "version:" {print $2}')" = "${version}" ]; then
        found_tag=$(git rev-parse --short "${tag}")
        break
      fi
    done
    
    if [ -z "$found_tag" ]; then
      echo "Can't find $chart $version in any version tag, removing it" >&2
      continue
    fi
    
    echo "$chart $version $found_tag"
  done < $miss_map
)

printf "%s\n" "$new_map" "$resolved_miss_map" | sort -k1,1 -k2,2 -V | awk '$1' > "$file"
