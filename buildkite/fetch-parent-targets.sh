#!/usr/bin/env bash
set -ueo pipefail

# Each Buildkite build stores the derivation target map as a pipeline
# artifact. This script determines the most appropriate commit (the
# fork point of the current chain from HEAD) and fetches the artifact.
#
# New builds can be based on HEAD before the pipeline for the last
# commit has finished, in which case it is possible that the fork
# point has no derivation map. To account for this, up to 3 commits
# prior to HEAD are also queried to find a map.
#
# If no map is found, the failure mode is not critical: We simply
# build all targets.

: ${DRVMAP_PATH:=pipeline/drvmap.json}

git fetch -v origin "${BUILDKITE_PIPELINE_DEFAULT_BRANCH}"

FIRST=$(git merge-base FETCH_HEAD "${BUILDKITE_COMMIT}")
SECOND=$(git rev-parse "$FIRST~1")
THIRD=$(git rev-parse "$FIRST~2")

function most_relevant_builds {
    set -u
    curl 'https://graphql.buildkite.com/v1' \
         --silent \
         -H "Authorization: Bearer $(cat /run/agenix/buildkite-graphql-token)" \
         -d "{\"query\": \"query { pipeline(slug: \\\"$BUILDKITE_ORGANIZATION_SLUG/$BUILDKITE_PIPELINE_SLUG\\\") { builds(commit: [\\\"$FIRST\\\",\\\"$SECOND\\\",\\\"$THIRD\\\"]) { edges { node { uuid }}}}}\"}" | \
         jq -r '.data.pipeline.builds.edges[] | .node.uuid'
}

mkdir -p tmp
for build in $(most_relevant_builds); do
    echo "Checking artifacts for build $build"
    buildkite-agent artifact download --build "${build}" "${DRVMAP_PATH}" 'tmp/' || true

    if [[ -f "tmp/${DRVMAP_PATH}" ]]; then
        echo "Fetched target map from build ${build}"
        mv "tmp/${DRVMAP_PATH}" tmp/parent-target-map.json
        break
    fi
done
