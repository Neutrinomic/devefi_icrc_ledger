#!/bin/sh

# Run build.sh command inside every mo_test* directory
find . -type d -name "mo_test*" | parallel -j0 'echo "Running build.sh inside {}"; cd {} && ./build.sh'
