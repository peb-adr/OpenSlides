#!/bin/bash

set -ae

ME=$(basename "$0")

STABLE_VERSION=
STABLE_BRANCH_NAME=
STAGING_BRANCH_NAME=
BRANCH_NAME=
REMOTE_NAME=
OPT_PULL=
OPT_LOCAL=

# do not page diff and log outputs
GIT_PAGER=

usage() {
cat <<EOF

Helper script to integrate new changes.

USAGE:
  $ME <MODE> [ --pull | -p ] [ -l | --local ]

MODES:

  fetch-all-changes
    Fetch all submodules latest upstream changes and check them out. This will
    leave them in detached HEAD state.
    Use --pull to instead forward the local branches.

  staging
    Create an update containing new changes that can be deployed for testing.
    In order to do so first fetch-all-changes is called. Then desired changes
    can be picked interactively and a new commit with appropriately adjusted
    submodule pointers is created on the main branch.

  stable
    Create an update based on a previous staging update. For this appropriate
    merge commits are created in the main repository as well as every affected
    submodule. These will then be attempted to be pushed directly into upstream.
    Use --local to skip pushing.

  hotfix
    Create an update based on changes in submodules stable branches. Will
    create a new commit in the main repositories stable analogous to the stable
    workflow. These will then be attempted to be pushed directly into upstream.
    Use --local to skip pushing.
    Changes must manually be reflected into the main branch afterwards.
EOF
}

ask() {
  local default_reply="$1" reply_opt="[y/N]" blank="y" REPLY=
  shift; [[ "$default_reply" != y ]] || {
    reply_opt="[Y/n]"; blank=""
  }

  read -rp "$@ $reply_opt: "
  case "$REPLY" in
    Y|y|Yes|yes|YES|"$blank") return 0 ;;
    *) return 1 ;;
  esac
}

abort() {
  echo "Aborting."
  exit "$1"
}

set_remote() {
  REMOTE_NAME=upstream
  git ls-remote --exit-code "$REMOTE_NAME" &>/dev/null ||
    REMOTE_NAME=origin
}

confirm_version() {
  set_remote
  STABLE_BRANCH_NAME="stable/$(awk -v FS=. -v OFS=. '{$3="x"  ; print $0}' VERSION)"  # 4.N.M -> 4.N.x
  git fetch $REMOTE_NAME $STABLE_BRANCH_NAME
  STABLE_VERSION="$(git show "$REMOTE_NAME/$STABLE_BRANCH_NAME:VERSION")"
  STAGING_VERSION="$(echo $STABLE_VERSION | awk -v FS=. -v OFS=. '{$3=$3+1 ; print $0}')"  # 4.N.M -> 4.N.M+1
  # Give the user the opportunity to adjust the calculated staging version
  read -rp "Please confirm the staging version to be used [${STAGING_VERSION}]: "
  case "$REPLY" in
    "") ;;
    *) STAGING_VERSION="$REPLY" ;;
  esac
  STAGING_BRANCH_NAME="staging/$STAGING_VERSION"
}

check_current_branch() {
  # Return 1 if remote branch does not exist
  git ls-remote --exit-code --heads "$REMOTE_NAME" "$BRANCH_NAME" &>/dev/null || {
    echo "No remote branch $REMOTE_NAME/$BRANCH_NAME found."
    return 1
  }

  # If remote branch exists ensure we are up-to-date with it
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH_NAME" ]] || {
    echo "ERROR: $BRANCH_NAME branch not checked out ($(basename $(realpath .)))"
    ask y "Run \`git checkout $BRANCH_NAME && git submodule update --recursive\` now?" &&
      git checkout $BRANCH_NAME && git submodule update --recursive ||
      abort 0
  }

  git fetch "$REMOTE_NAME" "$BRANCH_NAME"  # TODO: probably obsoleted by ls-remote above
  if git merge-base --is-ancestor "$BRANCH_NAME" "$REMOTE_NAME/$BRANCH_NAME"; then
    echo "git merge --ff-only $REMOTE_NAME/$BRANCH_NAME"
    git merge --ff-only "$REMOTE_NAME"/$BRANCH_NAME
  else
    ask n "$BRANCH_NAME and $REMOTE_NAME/$BRANCH_NAME have diverged. Run \`git reset --hard $REMOTE_NAME/$BRANCH_NAME\` now?" &&
      git reset --hard "$REMOTE_NAME/$BRANCH_NAME" ||
      abort 0
  fi
}

check_submodules_intialized() {
  # From `man git-submodule`:
  #   Each SHA-1 will possibly be prefixed with - if the submodule is not initialized
  git submodule status --recursive | awk '$1 ~ "^-" {print "  " $2; x=1} END {exit x}' || {
    echo "ERROR: Found the above uninitialized submodules. Please correct before rerunning $ME."
    abort 1
  }
}

pull_latest_commit() {
  if [ -z "$OPT_PULL" ]; then
    echo "git fetch $REMOTE_NAME && git checkout $REMOTE_NAME/$BRANCH_NAME && git submodule update ..."
    git fetch "$REMOTE_NAME" "$BRANCH_NAME" &&
    git checkout "$REMOTE_NAME/$BRANCH_NAME"
    git submodule update
  else
    echo "git checkout $BRANCH_NAME && git pull --ff-only $REMOTE_NAME $BRANCH_NAME && git submodule update ..."
    git checkout "$BRANCH_NAME" &&
    git pull --ff-only "$REMOTE_NAME" "$BRANCH_NAME" || {
      echo "ERROR: make sure a local branch $BRANCH_NAME exists and can be fast-forwarded to $REMOTE_NAME"
      abort 1
    }
    git submodule update
  fi
}

fetch_all_changes() {
  for mod in $(git submodule status | awk '{print $2}'); do
    (
      echo ""
      echo "$mod"
      cd "$mod"

      set_remote
      pull_latest_commit
    )
  done

  echo ""
  echo "Successfully updated all submodules to latest commit."
}

push_changes() {
  [[ -z "$OPT_LOCAL" ]] ||
    return 0

  [[ "$BRANCH_NAME" == staging/* ]] || [[ "$BRANCH_NAME" == stable/* ]] || {
    echo "ERROR: Refusing to push to branch $BRANCH_NAME."
    echo "ERROR: Only staging/* or stable/* branches should be pushed to directly."
    abort 1
  }

  echo "Attempting to push $BRANCH_NAME into $REMOTE_NAME."
  echo "Ensure you have proper access rights or use --local to skip pushing."
  ask y "Continue?" ||
    abort 0
  echo "Submodules first ..."
  git submodule foreach --recursive git push "$REMOTE_NAME" "$BRANCH_NAME"
  echo "Now main repository ..."
  git push "$REMOTE_NAME" "$BRANCH_NAME"
}

check_meta_consistency() {
  local target_rev="$1"
  local meta_sha=
  local meta_sha_last=
  local ret_code=0

  echo "Checking openslides-meta consistency ..."

  # Doing a nested loop rather than foreach --recursive as it's easier to get
  # both the path of service submod and the (potential) meta submod in one
  # iteration
  while read mod; do
    while read meta_name meta_path; do
      [[ "$meta_name" == 'openslides-meta' ]] ||
        continue

      # If target_rev is not specified we check the status of the currently
      # checked out HEAD in the service submod.
      # Note that this is different from target_rev being specified as 'HEAD'
      # as the service submod can be in a different state than recorded in HEAD
      # (e.g. changed commit pointer during staging-update)
      mod_target_rev=HEAD
      [[ "$target_rev" == "" ]] ||
        mod_target_rev="$(git rev-parse "${target_rev}:${mod}")"

      meta_sha="$(git -C "$mod" rev-parse "${mod_target_rev}:${meta_path}")"
      echo "  $meta_sha $mod"
      [[ -z "$meta_sha_last" ]] || [[ "$meta_sha" == "$meta_sha_last" ]] ||
        ret_code=1
      meta_sha_last="$meta_sha"
    done <<< "$(git -C $mod submodule foreach -q 'echo "$name $sm_path"')"
  done <<< "$(git submodule foreach -q 'echo "$sm_path"')"

  return $ret_code
}

add_changes() {
  diff_cmd="git diff --color=always --submodule=log"
  [[ "$($diff_cmd | grep -c .)" -gt 0 ]] ||
    abort 0
  echo ''
  echo "Current $BRANCH_NAME changes:"
  echo '--------------------------------------------------------------------------------'
  $diff_cmd
  echo '--------------------------------------------------------------------------------'
  ask y "Interactively choose from these?" &&
    for mod in $(git submodule status | awk '$1 ~ "^+" {print $2}'); do
      (
        set_remote
        local target_sha= mod_sha_old= mod_sha_new= log_cmd= merge_base=
        mod_sha_old="$(git diff --submodule=short "$mod" | awk '$1 ~ "^-Subproject" { print $3 }')"
        mod_sha_new="$(git diff --submodule=short "$mod" | awk '$1 ~ "^+Subproject" { print $3 }')"
	#merge_base="$(git merge-base "$BRANCH_NAME" main)"
        log_cmd="git -C $mod log --oneline --no-decorate $mod_sha_old..$mod_sha_new"
        #log_cmd="git -C $mod log --oneline --no-decorate $merge_base..$BRANCH_NAME $merge_base..$REMOTE_NAME/main"
        target_sha="$($log_cmd | awk 'NR==1 { print $1 }' )"

        echo ""
        echo "$mod changes:"
        echo "--------------------------------------------------------------------------------"
        $log_cmd
        echo "--------------------------------------------------------------------------------"
        read -rp "Please select a commit, '-' to skip [${target_sha}]: "
        case "$REPLY" in
          "") ;;
          *) target_sha="$REPLY" ;;
        esac
        [[ "$target_sha" != '-' ]] || {
          target_sha="$(git rev-parse "HEAD:$mod")"
          echo "Selecting ${target_sha:0:7} (currently referenced from HEAD) in order to skip ..."
        }

        git -C "$mod" checkout "$target_sha"
        git -C "$mod" submodule update
        git add "$mod"
      )
    done

  echo ''
  diff_cmd="git diff --staged --submodule=log"
  [[ "$($diff_cmd | grep -c .)" -gt 0 ]] || {
    echo "No changes added."
    abort 0
  }
  echo 'Changes to be included for the new update:'
  echo '--------------------------------------------------------------------------------'
  $diff_cmd
  echo '--------------------------------------------------------------------------------'
}

choose_changes() {
  ask y "Fetch all submodules $BRANCH_NAME changes now?" &&
    fetch_all_changes

  add_changes

  check_meta_consistency || {
    echo "WARN: openslides-meta is not consistent across services."
    echo "WARN: This means a $STAGING_BRANCH_NAME branch cannot be created in openslides-meta."
    echo "WARN: Please rectify and rerun $ME"
    abort 1
  }
}

commit_changes() {
  local commit_message="Updated services"
  [[ "$BRANCH_NAME" == main ]] &&
    commit_message="Updated services (pre staging update)"
  [[ "$BRANCH_NAME" == staging/* ]]
    commit_message="Staging update $(date +%Y%m%d)"
  [[ "$BRANCH_NAME" == stable/* ]] &&
    commit_message="Update $(cat VERSION) ($(date +%Y%m%d))"
  [[ $# == 0 ]] ||
    commit_message="$@"

  ask y "Commit on branch $BRANCH_NAME now?" && {
    git commit --message "$commit_message"
    git show --no-patch
  }
}

update_main_branch() {
  ask y "Update services and create a new commit on main branch now? This should be your
first step. If it was done before, or you are certain, $STAGING_BRANCH_NAME should branch
out from $REMOTE_NAME/main as it is now, you may answer 'n' to create a staging branch." ||
    return 1

  BRANCH_NAME=main
  check_current_branch

  choose_changes
  commit_changes
  echo "Commit created. Push to a remote and PR into main repo to bring it live."
  echo "After merging, rerun $ME and start creating a staging branch."
}

initial_staging_update() {
  ask y "Create new branch $BRANCH_NAME at $REMOTE_NAME/main, referenced HEADs in submodules as well as openslides-meta
to fixate changes for a new staging update now?" ||
    abort 0

  set_remote

  echo "\$ git checkout --no-track -B $BRANCH_NAME $REMOTE_NAME/main"
  git checkout --no-track -B "$BRANCH_NAME" "$REMOTE_NAME/main"

  echo "Updating submodules and creating local $BRANCH_NAME branches"
  echo "\$ git submodule update --recursive"
  git submodule update --recursive
  for repo in $(git submodule status --recursive | awk '{print $2}'); do
    echo "\$ git -C $repo checkout --no-track -B $BRANCH_NAME"
    git -C "$repo" checkout --no-track -B "$BRANCH_NAME"
  done

  # Update VERSION
  echo "$STAGING_VERSION" > VERSION
  git diff --quiet VERSION && {
    echo "ERROR: $STAGING_VERSION does not seem to differ from version number present in VERSION."
    abort 1
  }
  git add VERSION

  commit_changes
  push_changes
}

make_staging_update() {
  local diff_cmd=

  if check_current_branch; then
    # A fitting staging/* branch exists and we can add new remote changes to
    # create a new staging update for the same version
    choose_changes
    push_changes
  else
    # No fitting staging/* branch exists yet. Offer to Update main branches
    # first or create staging branches right away
    if update_main_branch; then
      return 0
    else
      initial_staging_update
    fi
  fi
}

make_hotfix_update() {
  # TODO: Reconsider the hotfix workflow
  local diff_cmd=

  add_changes

  check_meta_consistency || {
    echo "WARN: openslides-meta is not consistent. This is not a good sign for stable update."
    echo "WARN: Only continue if you are sure services will be compatible."
    ask n "Continue?" ||
      abort 1
  }

  ask y "Commit on branch $BRANCH_NAME for a new stable (hotfix) update now?" && {
    increment_patch &&
      git add VERSION
    git commit --message "Update $(cat VERSION) ($(date +%Y%m%d))"
    git show --no-patch
    echo "Commit created."
  }

  push_changes
}

merge_stable_branches() {
  local target_sha="$1"
  local mod_target_sha=
  local diff_cmd=

  echo "Creating merge commits in submodules..."
  ask y "Continue?" ||
    abort 0

  for mod in $(git submodule status --recursive | awk '{print $2}'); do
    diff_cmd="git diff --submodule=short $BRANCH_NAME $target_sha $mod"
    [[ "$($diff_cmd | grep -c .)" -gt 0 ]] ||
      continue

    mod_target_sha="$($diff_cmd | awk '$1 ~ "^+Subproject" { print $3 }')"
    (
      echo ""
      echo "$mod"
      cd "$mod"

      set_remote
      git checkout "$BRANCH_NAME"
      git submodule update
      check_current_branch

      git merge --no-ff -Xtheirs "$mod_target_sha" --log --message "Merge $STAGING_BRANCH_NAME into $STABLE_BRANCH_NAME. Update $(date +%Y%m%d)"
    )
  done

  echo ""
  echo "Updated submodules $BRANCH_NAME branches."
}

make_stable_update() {
  local target_sha= log_cmd= REPLY=

  set_remote
  check_current_branch

  echo "git fetch $REMOTE_NAME $STAGING_BRANCH_NAME"
  git fetch "$REMOTE_NAME" "$STAGING_BRANCH_NAME"

  log_cmd="git log --oneline --no-decorate $STABLE_BRANCH_NAME..$REMOTE_NAME/$STAGING_BRANCH_NAME"
  [[ "$($log_cmd | grep -c . )" -gt 0 ]] || {
    echo "ERROR: No staging update ahead of the latest stable update found."
    abort 1
  }
  target_sha="$($log_cmd | awk 'NR==1 { print $1 }')"

  echo 'Staging updates since last stable update:'
  echo '--------------------------------------------------------------------------------'
  $log_cmd
  echo '--------------------------------------------------------------------------------'
  read -rp "Please confirm the staging update to base this stable update on [${target_sha}]: "
  case "$REPLY" in
    "") ;;
    *) target_sha="$REPLY" ;;
  esac

  check_meta_consistency "$target_sha" || {
    echo "ERROR: openslides-meta is not consistent at $target_sha. This is not acceptable for a stable update."
    echo "ERROR: Please fix this in a new staging update before trying again."
    abort 1
  }

  merge_stable_branches "$target_sha"

  # Merge, but don't commit yet ...
  # (also we expect conflicts in submodules so we hide that output)
  git merge -Xtheirs --no-commit --no-ff "$target_sha" --log >/dev/null || :
  # ... because we want to change the submod pointers to stable
  for mod in $(git submodule status | awk '{print $2}'); do
    git add "$mod"
  done
  # Now commit the merge with corrected submodule pointers
  commit_changes

  push_changes
}


shortopt='phl'
longopt='pull,help,local'
ARGS=$(getopt -o "$shortopt" -l "$longopt" -n "$ME" -- $@)
# reset $@ to args array sorted and validated by getopt
eval set -- "$ARGS"
unset ARGS


while true; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -p | --pull)
      OPT_PULL=1
      shift
      ;;
    -l | --local)
      OPT_LOCAL=1
      shift
      ;;
    --) shift ; break ;;
    *) usage; exit 1 ;;
  esac
done

# $ME assumes all submodules to be initialized, so check before doing anything else
check_submodules_intialized

for arg; do
  case $arg in
    fetch-all-changes)
      BRANCH_NAME=main
      fetch_all_changes
      check_meta_consistency ||
        echo "WARN: openslides-meta is not consistent."
      shift 1
      ;;
    staging)
      confirm_version
      BRANCH_NAME=$STAGING_BRANCH_NAME
      make_staging_update
      shift 1
      ;;
    stable)
      confirm_version
      BRANCH_NAME=$STABLE_BRANCH_NAME
      make_stable_update
      shift 1
      ;;
    hotfix)
      confirm_version
      BRANCH_NAME=$STABLE_BRANCH_NAME
      make_hotfix_update
      shift 1
      ;;
  esac
done
