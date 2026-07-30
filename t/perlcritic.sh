#!/bin/sh
#
# perlcritic at --severity 4, gated against a checked-in baseline.
#
# A plain "fail on any violation" gate is not usable here: handle_metadata
# carries five known violations at severity 4 and 5, every one of them a bug
# that is deliberately still present (see t/perlcritic.baseline). Making the
# check red from day one would either wedge the branch ruleset or train
# everyone to ignore it.
#
# So the gate is differential. The current violations, reduced to
# <file> <policy> and sorted, are compared against the baseline:
#
#   * a violation not in the baseline  -> FAIL (a new problem)
#   * a baseline entry no longer hit   -> FAIL (fixed; drop it from the file)
#
# Refresh the baseline with:  t/perlcritic.sh --update
#
# PERLCRITIC may name a wrapper; by default the tool is expected on PATH.

set -u

##############################################################################
# Settings

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$here/.." && pwd)

PERLCRITIC=${PERLCRITIC:-perlcritic}
SEVERITY=${SEVERITY:-4}

baseline="$here/perlcritic.baseline"

targets='handle_metadata t'

#-----------------------------------------------------------------------------
# Emit "<file> <policy>" per violation, sorted and deduplicated.
#
# Line numbers are deliberately left out: they churn on every edit and would
# make the baseline useless. Policy-per-file is the stable unit.
#
# "<file> source OK" lines are perlcritic's clean-file notices, and the
# "Policy ... is not installed" warnings come from .perlcriticrc naming
# policies this build of Perl::Critic does not ship. Neither is a violation.

current_violations() {

  # shellcheck disable=SC2086
  ( cd -- "$root" && $PERLCRITIC --severity "$SEVERITY" --verbose '%f %p%n' $targets 2>/dev/null ) \
    | grep -v ' source OK$' \
    | grep -v '^Policy .* is not installed\.$' \
    | sed '/^$/d' \
    | sort -u

}

##############################################################################
# Main

if ! command -v "$PERLCRITIC" >/dev/null 2>&1; then
  echo "perlcritic.sh: '$PERLCRITIC' is not on PATH" >&2
  exit 2
fi

actual=$(current_violations)

if [ "${1:-}" = '--update' ]; then

  {
    sed -n '1,/^# END HEADER$/p' "$baseline" 2>/dev/null
    printf '%s\n' "$actual"
  } > "$baseline.new"

  mv "$baseline.new" "$baseline"

  echo "perlcritic.sh: baseline refreshed; review the diff before committing"
  exit 0

fi

if [ ! -f "$baseline" ]; then
  echo "perlcritic.sh: $baseline is missing; run 't/perlcritic.sh --update'" >&2
  exit 2
fi

expected=$(grep -v '^#' "$baseline" | sed '/^$/d' | sort -u)

if [ "$actual" = "$expected" ]; then
  printf 'perlcritic: severity %s, %s known violation(s), none new\n' \
    "$SEVERITY" "$(printf '%s' "$expected" | grep -c . || true)"
  exit 0
fi

echo 'perlcritic: the violation set does not match t/perlcritic.baseline' >&2
echo >&2
echo '  - lines are violations that have gone away (drop them from the baseline)' >&2
echo '  + lines are NEW violations (fix them)' >&2
echo >&2

printf '%s\n' "$expected" > /tmp/perlcritic-expected.$$
printf '%s\n' "$actual"   > /tmp/perlcritic-actual.$$

diff -u /tmp/perlcritic-expected.$$ /tmp/perlcritic-actual.$$ >&2

rm -f /tmp/perlcritic-expected.$$ /tmp/perlcritic-actual.$$

exit 1
