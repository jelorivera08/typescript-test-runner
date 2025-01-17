#!/bin/bash

# Synopsis:
# Automatically tests exercism's JS track solutions against corresponding test files.
# Takes two-three arguments and makes sure all the tests are run

# Arguments:
# $1: exercise slug
# $2: path to solution folder (with trailing slash)
# $3: path to output directory (with trailing slash) (defaults to $2)

# Output:
# Writes the tests output to the output directory

# Example:
# ./run.sh two-fer path/to/two-fer/solution/folder/
# ./run.sh two-fer path/to/two-fer/solution/folder/ path/to/output-directory/

if [[ $1 != http?(s)://* ]]; then
  if [ -z "$2" ] ; then
    echo "Requires at least 2 arguments:"
    echo "1: exercise slug"
    echo "2: path to solution folder (with trailing slash)"
    echo ""
    echo "Usage:"
    echo "  run.sh two-fer path/to/two-fer/solution/folder/"
    exit 1
  fi

  if [ -z "$3" ] ; then
    OUTPUT="$2"
  else
    OUTPUT="$3"
  fi

  INPUT="$2"
  SLUG="$1"
else
  # This block allows you to download a solution and run the tests on it. This
  # allows passing in any solution URL your locally installed exercism CLI has
  # access to:
  #
  # - published: https://exercism.io/tracks/typescript/exercises/clock/solutions/c3b826d95cb54441a8f354d7663e9e16
  # - private: https://exercism.io/solutions/c3b826d95cb54441a8f354d7663e9e16
  #
  uuid=$(basename $1)
  echo "Exercism remote UUID: $uuid"

  result=$(exercism download --uuid="${uuid}" | sed -n 1p) || exit $?
  echo $result

  SLUG=$(basename $result)
  TMP="./tmp/${SLUG}/${uuid}/"

  # Jest really doesn't like it when the input files are outside the CWD process
  # tree. Instead of trying to resolve that, the code here copies the downloaded
  # solution to a local temporary directory.
  #
  # This will fail if the cwd is not writable.
  #
  mkdir -p "$TMP"
  cp "$result" "$TMP" -r

  INPUT="$TMP$SLUG/"
  OUTPUT=$INPUT
fi

# Forces a trailing slash
INPUT="${INPUT//\\//}"
INPUT="${INPUT%/}/"

# Forces a trailing slash
OUTPUT="${OUTPUT//\\//}"
OUTPUT="${OUTPUT%/}/"

set -euo pipefail

ROOT="$(realpath $(dirname "$0")/..)"
REPORTER="$ROOT/dist/reporter.js"
SETUP="$ROOT/dist/jest/setup.js"

if test -f "$REPORTER"; then
  echo "Using reporter : $REPORTER"
  echo "Using test-root: $INPUT"
  echo "Using base-root: $ROOT"
  echo "Using setup-env: $SETUP"

  echo ""
else
  >&2 echo "Expected reporter.js to exist. Did you forget to yarn build first?"
  >&2 echo "Using reporter : $REPORTER"
  >&2 echo "Using test-root: $INPUT"
  >&2 echo "Using base-root: $ROOT"
  >&2 echo "Using setup-env: $SETUP"
  >&2 echo ""
  >&2 echo "The following files exist in the dist folder (build output):"
  >&2 echo $(ls $ROOT/dist)
  exit 1
fi

echo ""

configuration_file="${INPUT}.meta/config.json"

# Prepare the test file(s)

if test -f $configuration_file; then
  echo "Using ${configuration_file} as base configuration"
  cat $configuration_file | jq -c '.files.test[]' | xargs -L 1 "$ROOT/bin/prepare.sh" ${INPUT}
else
  test_file="${SLUG}.test.ts"
  echo "No configuration given. Falling back to ${test_file}"
  "$ROOT/bin/prepare.sh" ${INPUT} ${test_file}
fi;

# Put together the path to the test results file
result_file="${OUTPUT}results.json"

mkdir -p "${OUTPUT}"

# Disable auto exit
set +e

# Run tsc
cp -r "$ROOT/node_modules/@types" "$INPUT/node_modules"

if test -f "${INPUT}tsconfig.json"; then
  echo "Found tsconfig.json; disabling test compilation"
  sed -i 's/, "\.meta\/\*"//' "${INPUT}tsconfig.json"
  sed -i 's/"node_modules"/"node_modules", "*.test.ts", ".meta\/*"/' "${INPUT}tsconfig.json"
fi;

echo "Running tsc"
tsc_result="$( cd "${INPUT}" && "$ROOT/node_modules/.bin/tsc" --noEmit 2>&1 )"
test_exit=$?

echo "$tsc_result" > $result_file
sed -i 's/"/\\"/g' $result_file

if test -f "${INPUT}tsconfig.json"; then
  echo "Found tsconfig.json; enabling test compilation"
  sed -i 's/\["\*"\]/["*", ".meta\/*"]/' "${INPUT}tsconfig.json"
  sed -i 's/"node_modules", "\*\.test\.ts", "\.meta\/\*"/"node_modules"/' "${INPUT}tsconfig.json"
fi;

if [ $test_exit -eq 2 ]
then
  echo "tsc compilation failed"

  # Compose the message to show to the student
  #
  # TODO: interpret the tsc_result lines and pull out the source.
  #       We actually already have code to do this, given the cursor position
  #
  tsc_result=$(cat $result_file)
  tsc_result="The submitted code didn't compile. We have collected the errors encountered during compilation. At this moment the error messages are not very read-friendly, but it's a start. We are working on a more helpful output.\n-------------------------------\n$tsc_result"
  echo "{ \"version\": 1, \"status\": \"error\", \"message\": \"$tsc_result\" }" > $result_file
  sed -Ei ':a;N;$!ba;s/\r{0,1}\n/\\n/g' $result_file
  # Test runner didn't fail!
  exit 0
else
  echo "tsc compilation success"
fi

# Run tests
( "$ROOT/node_modules/.bin/jest" "${INPUT}*" \
                               --outputFile="${result_file}" \
                               --reporters "${REPORTER}" \
                               --noStackTrace \
                               --verbose=false \
                               --roots "${INPUT}" \
                               --passWithNoTests \
                               --ci \
                               --runInBand \
                               --bail 1 \
                               --setupFilesAfterEnv ${SETUP} )

# Convert exit(1) (jest worked, but there are failing tests) to exit(0)
test_exit=$?

echo ""
echo "Find the output at:"
echo $result_file

if [ $test_exit -eq 1 ]
then
  exit 0
else
  exit $test_exit
fi
