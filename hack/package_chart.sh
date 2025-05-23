#!/bin/sh

set -e

usage() {
        printf "%s\n" "Usage:" >&2 ;
        printf -- "%s\n" '---' >&2 ;
        printf "%s %s\n" "$0" "INPUT_DIR OUTPUT_DIR TMP_DIR [DEPENDENCY_DIR]" >&2 ;
        printf -- "%s\n" '---' >&2 ;
        printf "%s\n" "Takes a helm repository from INPUT_DIR, with an optional library repository in" >&2 ;
        printf "%s\n" "DEPENDENCY_DIR, prepares a view of the git archive at select points in history" >&2 ;
        printf "%s\n" "in TMP_DIR and packages helm charts, outputting the tarballs to OUTPUT_DIR" >&2 ;
}

if [ "x$(basename $PWD)" != "xpackages" ]
then
        echo "Error: This script must run from the ./packages/ directory" >&2
        echo >&2
        usage
        exit 1
fi

if [ "x$#" != "x3" ] && [ "x$#" != "x4" ]
then
        echo "Error: This script takes 3 or 4 arguments" >&2
        echo "Got $# arguments:" "$@" >&2
        echo >&2
        usage
        exit 1
fi

input_dir=$1
output_dir=$2
tmp_dir=$3

if [ "x$#" = "x4" ]
then
        dependency_dir=$4
fi

rm -rf "${output_dir:?}"
mkdir -p "${output_dir}"
while read package _ commit
do
        # this lets devs build the packages from a dirty repo for quick local testing
        if [ "x$commit" = "xHEAD" ]
        then
                helm package "${input_dir}/${package}" -d "${output_dir}"
                continue
        fi
        git archive --format tar "${commit}" "${input_dir}/${package}" | tar -xf- -C "${tmp_dir}/"

        # the library chart is not present in older commits and git archive doesn't fail gracefully if the path is not found
        if [ "x${dependency_dir}" != "x" ] && git ls-tree --name-only "${commit}" "${dependency_dir}" | grep -qx "${dependency_dir}"
        then
                git archive --format tar "${commit}" "${dependency_dir}" | tar -xf- -C "${tmp_dir}/"
        fi
        helm package "${tmp_dir}/${input_dir}/${package}" -d "${output_dir}"
        rm -rf "${tmp_dir:?}/${input_dir:?}/${package:?}"
        if [ "x${dependency_dir}" != "x" ]
        then
                rm -rf "${tmp_dir:?}/${dependency_dir:?}"
        fi
done < "${input_dir}/versions_map"
helm repo index "${output_dir}"
