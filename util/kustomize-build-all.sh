#!/bin/bash

# This script is intended to be run from the root of this repo, as in:
#
#   ./util/kustomize-build-all.sh
#
# This script detects any overlay environments defined in this repo and attempts to build them all.
# It prints a report of each build, then exits with 0 if everything builds successfully, else 1.


echo '***** KUSTOMIZE BUILD REPORT *****'
echo

# Work within the overlays directory
pushd overlays &> /dev/null

# Discover all overlay directories and try to `kustomize build` them
FAIL_COUNT=0
for overlay in $(ls -d *); do
    echo "-- $overlay:"
    output=$(kustomize build $overlay 2>&1 )
    rc=$?

    # Report output on failed builds so we can react
    echo -n 'Build status: '
    if [ $rc -ne 0 ]; then
        FAIL_COUNT=$((FAIL_COUNT+1))
        echo '❌'
        echo
        echo "Output: $output"
        echo
    else
        echo '✅'
        echo
    fi
done

popd &> /dev/null

echo "Total build failures: $FAIL_COUNT"

# Exit with error code if any failures occurred
if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
else
    exit 0
fi
