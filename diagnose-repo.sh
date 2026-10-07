#!/usr/bin/env bash
# READ-ONLY. Tells you where your store files actually are in this repo, whether
# git is tracking them, and what Vercel's Root Directory setting should be.
# Changes nothing. Run it inside your repository folder:
#     bash diagnose-repo.sh
set -u

echo "Folder you ran this from : $(pwd)"
echo "Git remote               : $(git config --get remote.origin.url 2>/dev/null || echo 'none set')"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Branch                   : $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "Uncommitted changes      : $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s)"
fi
echo

found=0
for dir in . online-store store thetieguy-online-store thetieguy-online-store-deploy; do
  [ -f "$dir/package.json" ] || continue
  found=$((found + 1))
  name=$(grep -m1 '"name"' "$dir/package.json" | sed 's/.*: *"\(.*\)".*/\1/')
  on_disk=0; [ -d "$dir/app" ] && on_disk=$(find "$dir/app" -type f 2>/dev/null | wc -l | tr -d ' ')
  tracked=$(git ls-files "$dir/app" 2>/dev/null | wc -l | tr -d ' ')
  echo "package.json found in : $dir    (package name: $name)"
  echo "  app/ files on disk  : $on_disk"
  echo "  app/ tracked by git : $tracked      <- this is what Vercel receives"
  echo "  Vercel Root Directory should be: $( [ "$dir" = "." ] && echo '(leave empty — repo root)' || echo "$dir" )"
  if [ "$on_disk" -eq 0 ]; then
    echo "  !! NO app/ folder here. Next.js will fail with:"
    echo "     \"Couldn't find any 'pages' or 'app' directory\""
  elif [ "$tracked" -eq 0 ]; then
    echo "  !! app/ is on disk but NOT committed. Run: git add -A && git commit -m \"store\" && git push"
  else
    echo "  ok: app/ exists and is committed — this folder is deployable"
  fi
  echo
done

if [ "$found" -eq 0 ]; then
  echo "No package.json found in the checked locations (., online-store, store, thetieguy-online-store*,)."
  echo "You are probably in the wrong folder — cd into your repository first."
fi

cat <<'NOTE'

How to read this:
  * Vercel builds the files GIT tracks at the project's Root Directory setting.
  * One package.json + app/ -> set Root Directory to that folder (empty if it is the repo root).
  * If your repo holds BOTH projects (dashboard at the root, store in a subfolder), the
    store's package.json must stay INSIDE the store folder — never copy it to the repo
    root, or the dashboard's build breaks and the store builds in the wrong place.
  * Next.js looks for app/ (or pages/) at whatever level Root Directory points to.
NOTE
