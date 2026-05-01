#!/usr/bin/env bash
set -e

PREFIX="$1"

if [ -z "$PREFIX" ]; then
  echo "Usage: $0 <prefix>"
  exit 1
fi

# Extract core commit data
TREE=$(git rev-parse HEAD^{tree})

# Handle root commit (no parent)
if git rev-parse HEAD^ >/dev/null 2>&1; then
  PARENT=$(git rev-parse HEAD^)
else
  PARENT=""
fi

# This structure in the commit hash needs the unix timestamp, not the formatted date
AUTHOR_NAME=$(git log -1 --pretty=%an)
AUTHOR_EMAIL=$(git log -1 --pretty=%ae)
AUTHOR_DATE=$(git log -1 --pretty=%at)
AUTHOR_TZ=$(git log -1 --pretty=%ai | awk '{print $NF}')

COMMITTER_NAME=$(git log -1 --pretty=%cn)
COMMITTER_EMAIL=$(git log -1 --pretty=%ce)
COMMITTER_DATE=$(git log -1 --pretty=%ct)
COMMITTER_TZ=$(git log -1 --pretty=%ci | awk '{print $NF}')

AUTHOR="$AUTHOR_NAME <$AUTHOR_EMAIL> $AUTHOR_DATE $AUTHOR_TZ"
COMMITTER="$COMMITTER_NAME <$COMMITTER_EMAIL> $COMMITTER_DATE $COMMITTER_TZ"



MESSAGE=$(git log -1 --pretty=%B)

echo "----------------------------------"
echo "Tree:      $TREE"
echo "Parent:    $PARENT"
echo "Author:    $AUTHOR"
echo "Committer: $COMMITTER"
echo "Message:"
echo "$MESSAGE"
echo "----------------------------------"

payload=$(jq -n \
  --arg prefix "$PREFIX" \
  --arg tree "$TREE" \
  --arg parent "$PARENT" \
  --arg author "$AUTHOR" \
  --arg committer "$COMMITTER" \
  --arg message "$MESSAGE" \
  '{prefix:$prefix, tree:$tree, parent:$parent, author:$author, committer:$committer, message:$message}')



SSH_TARGET="root@pm3.chamit.co.uk"   # <-- CHANGE THIS
REMOTE_BIN="/tmp/vanity_git"  # <-- adjust if needed

OUTPUT=$(ssh "$SSH_TARGET" "$REMOTE_BIN" <<< "$payload")

# Call your vanity generator
OUTPUT2=$(/home/wol/Code/git-vanity/vanity_git <<< "$payload")

echo "Output is:"
echo "$OUTPUT"
echo "----------"

echo "Output2 is:"
echo "$OUTPUT2"
echo "----------"


# -----------------------------
# 3. Extract nonce from output
# -----------------------------
NONCE=$(echo "$OUTPUT" | awk '/Nonce:/ {print $2}')

if [ -z "$NONCE" ]; then
  echo "Failed to extract nonce"
  exit 1
fi

echo "Using nonce: $NONCE"

# -----------------------------
# 4. Rebuild message with nonce
# -----------------------------
NEW_MESSAGE="${MESSAGE}
nonce: ${NONCE}
"

# -----------------------------
# 5. Recreate commit with fixed metadata
# -----------------------------

# This date is the formatted dat, not timestamp
AUTHOR_DATE=$(git log -1 --format='%aD')
COMMITTER_DATE=$(git log -1 --format='%cD')

export GIT_AUTHOR_NAME="$AUTHOR_NAME"
export GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL"
export GIT_AUTHOR_DATE="$AUTHOR_DATE"

export GIT_COMMITTER_NAME="$COMMITTER_NAME"
export GIT_COMMITTER_EMAIL="$COMMITTER_EMAIL"
export GIT_COMMITTER_DATE="$COMMITTER_DATE"


NEW_COMMIT=$(
  printf "%s" "$NEW_MESSAGE" | \
  git commit-tree "$TREE" \
    ${PARENT:+-p "$PARENT"}
)


# -----------------------------
# 6. Replace current HEAD
# -----------------------------
git reset --hard "$NEW_COMMIT"

echo "----------------------------------"
echo "New commit created:"
git log -1 --oneline
echo "----------------------------------"


