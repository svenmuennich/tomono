#!/bin/bash

# Merge multiple repositories into one big monorepo. Migrates every branch in
# every subrepo to the eponymous branch in the monorepo, with all files
# (including in the history) rewritten to live under a subdirectory.
#
# To use a separate temporary directory while migrating, set the GIT_TMPDIR
# envvar.
#
# To access the individual functions instead of executing main, source this
# script from bash instead of executing it.

${DEBUGSH:+set -x}
if [[ "$BASH_SOURCE" == "$0" ]]; then
	is_script=true
	set -eu -o pipefail
else
	is_script=false
fi

# Default name of the mono repository (override with envvar)
: "${MONOREPO_NAME=core}"

# Monorepo directory
monorepo_dir="$PWD/$MONOREPO_NAME"



##### FUNCTIONS

# Silent pushd/popd
pushd () {
	command pushd "$@" > /dev/null
}

popd () {
	command popd "$@" > /dev/null
}

function read_repositories {
	sed -e 's/#.*//' | grep .
}

# Simply list all files, recursively. No directories.
function ls-files-recursive {
	find . -type f | sed -e 's!..!!'
}

# List all branches for a given remote
function remote-branches {
	# With GNU find, this could have been:
	#
	#   find "$dir/.git/yada/yada" -type f -printf '%P\n'
	#
	# but it's not a real shell script if it's not compatible with a 14th
	# century OS from planet zorploid borploid.

	# Get into that git plumbing.  Cleanest way to list all branches without
	# text editing rigmarole (hard to find a safe escape character, as we've
	# noticed. People will put anything in branch names).
	pushd "$monorepo_dir/.git/refs/remotes/$1/"
	ls-files-recursive
	popd
}

# Create a monorepository in a directory "core". Read repositories from STDIN:
# one line per repository, with two space separated values:
#
# 1. The (git cloneable) location of the repository
# 2. The name of the target directory in the core repository
function create-mono {
	# Pretty risky, check double-check!
	if [[ "${1:-}" == "--continue" ]]; then
		if [[ ! -d "$MONOREPO_NAME" ]]; then
			echo "--continue specified, but nothing to resume" >&2
			exit 1
		fi
		pushd "$MONOREPO_NAME"
	else
		if [[ -d "$MONOREPO_NAME" ]]; then
			echo "Target repository directory $MONOREPO_NAME already exists." >&2
			return 1
		fi
		mkdir "$MONOREPO_NAME"
		pushd "$MONOREPO_NAME"
		git init
	fi

	# This directory will contain all final tag refs (namespaced)
	mkdir -p .git/refs/namespaced-tags

	read_repositories | while read repo name folder; do

		if [[ -z "$name" ]]; then
			echo "pass REPOSITORY NAME pairs on stdin" >&2
			return 1
		elif [[ "$name" = */* ]]; then
			echo "Forward slash '/' not supported in repo names: $name" >&2
			return 1
		fi

		if [[ -z "$folder" ]]; then
			folder="$name"
		fi

		remote_name="$name-origin"

		echo "Merging in $repo.." >&2
		git remote add "$remote_name" "$repo"
		echo "Fetching $remote_name.." >&2
		git fetch -q "$remote_name"

		# Now we've got all tags in .git/refs/tags: put them away for a sec
		if [[ -n "$(ls .git/refs/tags)" ]]; then
			mv .git/refs/tags ".git/refs/namespaced-tags/$name"
		fi

		# Merge every branch from the sub repo into the mono repo, into a
		# branch of the same name (create one if it doesn't exist).
		remote-branches "$remote_name" | while read source_branch; do
			if [[ "$source_branch" == "master" ]]; then
				destination_branch="$source_branch"
			else
				destination_branch="$name/$source_branch"
			fi
			echo "Merging branch $source_branch into $destination_branch.."
			if git rev-parse -q --verify "$destination_branch"; then
				# Branch already exists, just check it out (and clean up the working dir)
				echo "Using existing branch $destination_branch.."
				git checkout -q "$destination_branch"
				git checkout -q -- .
				git clean -f -d
			else
				# Create a fresh branch with an empty root commit
				echo "Creating new branch $destination_branch.."
				git checkout -q --orphan "$destination_branch"
				# The ignore unmatch is necessary when this was a fresh repo
				git rm -rfq --ignore-unmatch .
				if [[ "$destination_branch" == "master" ]]; then
					git commit -q --allow-empty -m "Initial commit"
				fi
			fi
			git merge -q --no-commit -s ours "$remote_name/$source_branch" --allow-unrelated-histories
			git read-tree --prefix="$folder/" "$remote_name/$source_branch"
			git commit -q --no-verify --allow-empty -m "Integrate \`$name\`"
		done
	done

	# Move all namespaced tags
	rm -rf .git/refs/tags
	mkdir -p .git/refs/tags
	find .git/refs/namespaced-tags -type f -exec bash -c 'mv {} ".git/refs/tags/$(basename $(dirname {}))-$(echo $(basename {}) | sed -r s/v?\([^v]+\)/\\\1/)"' \;
	rm -rf .git/refs/namespaced-tags

	git checkout -q master
	git checkout -q .
}

if [[ "$is_script" == "true" ]]; then
	create-mono "${1:-}"
fi
