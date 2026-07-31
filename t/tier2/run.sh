#!/bin/sh
#
# Tier 2 -- the tier 1 suite across a matrix of perl versions, in unprivileged
# containers.
#
# SCAFFOLD. The matrix, the image list, and the availability probe below are
# real; no tier-2-specific tests exist yet, so the runner reports SKIP (77)
# rather than pretending to pass. Filling it in means dropping the `exit 77`
# and letting run_matrix do its work.
#
# Exit status: 0 pass, 77 skip, anything else fail.

set -u

##############################################################################
# Settings

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$here/../.." && pwd)

SKIP_STATUS=77

# Verified against the Docker Hub registry API on 2026-07-30.
#
# perl:5.14 through perl:5.20 still exist as tags but are published as schema-1
# (application/vnd.docker.distribution.manifest.v1+prettyjws) manifests, which
# modern docker refuses to pull:
#
#   docker: Error response from daemon: unsupported manifest media type
#
# perl:5.22 is the oldest tag with a schema-2 manifest, so it -- not the 5.14
# that `use 5.014` declares -- is the real floor this matrix can test.
PERL_IMAGES=${PERL_IMAGES:-'perl:5.22 perl:5.26 perl:5.30 perl:5.34 perl:5.38 perl:5.42'}

##############################################################################

run_matrix() {

  status=0

  for image in $PERL_IMAGES; do

    printf '\n--- %s ---\n' "$image"

    # The repository is mounted read-only: the suite writes only to temporary
    # directories, and a tier that could modify the checkout would be able to
    # mask a failure.
    docker run --rm \
      --volume "$root:/src:ro" \
      --workdir /tmp/gitperms \
      "$image" \
      sh -c 'cp -a /src /tmp/gitperms && cd /tmp/gitperms && prove -I t/lib t' \
      || status=1

  done

  return $status

}

##############################################################################
# Main

if ! command -v docker >/dev/null 2>&1; then
  echo 'tier 2: docker is not installed'
  exit "$SKIP_STATUS"
fi

if ! docker info >/dev/null 2>&1; then
  echo 'tier 2: docker is installed but not usable'
  exit "$SKIP_STATUS"
fi

echo 'tier 2: no tests implemented yet (scaffold only)'
echo "tier 2: the matrix, once enabled, will be: $PERL_IMAGES"

exit "$SKIP_STATUS"

# Reached once tier 2 is filled in:
# run_matrix
