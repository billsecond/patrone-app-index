#!/bin/bash
# Builds Patrone's app index: a Flatpak repository with a reference to each
# app in apps.list and none of the apps. A reference is the app's listing
# (name, icon, description and permissions, from the .flatpak on its latest
# GitHub release) and the address and checksum of the Linux tarball on that
# release. Flatpak downloads the tarball from the project's release when
# someone installs the app (Flatpak's "extra data", as Flathub does for
# Spotify), so the index stays a few megabytes.
#
#   build-index.sh REPO [GPG-KEY-ID]
#
# REPO is made if it's missing. An app whose release (and apply_extra)
# hasn't changed keeps its commit, so installed copies aren't updated for
# nothing. Needs curl, jq,
# ostree and flatpak; GITHUB_TOKEN, if set, goes to GitHub's API, and
# GPG_HOMEDIR to the signing.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$1
key=${2:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sign=()
[ -n "$key" ] && sign=(--gpg-sign="$key" ${GPG_HOMEDIR:+--gpg-homedir="$GPG_HOMEDIR"})

if [ -d "$repo/objects" ]; then
    # Git (the published copy) keeps no empty folders, and OSTree wants these.
    mkdir -p "$repo"/{tmp,state,extensions,refs/heads,refs/mirrors,refs/remotes}
else
    ostree init --repo="$repo" --mode=archive-z2
fi
ostree init --repo="$work/bundles" --mode=bare-user-only
changed=
listed=" "

api() {
    curl -fsSL -H 'Accept: application/vnd.github+json' \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "https://api.github.com/$1"
}

while read -r project id prefix; do
    [[ -z $project || $project == \#* ]] && continue
    listed+="$id "
    release=$(api "repos/$project/releases/latest")
    tag=$(jq -r .tag_name <<<"$release")
    asset() { jq -ec --arg re "$1" 'first(.assets[] | select(.name | test($re)))' <<<"$release"; }
    if ! tarball=$(asset "^$prefix-[0-9].*-linux-x86_64\\.tar\\.gz\$") ||
       ! bundle=$(asset "^$prefix-[0-9].*-linux-x86_64\\.flatpak\$"); then
        echo "$id: $project $tag has no Linux tarball and .flatpak, skipped" >&2
        continue
    fi
    url=$(jq -r .browser_download_url <<<"$tarball")
    size=$(jq -r .size <<<"$tarball")
    sum=$(jq -r '.digest // "" | ltrimstr("sha256:")' <<<"$tarball")
    if [ -z "$sum" ]; then
        # Releases from before GitHub kept checksums (mid-2025).
        sum=$(curl -fsSL "$url" | sha256sum | cut -d' ' -f1)
    fi
    ref=app/$id/x86_64/stable
    if ostree --repo="$repo" cat "$ref" /metadata 2>/dev/null | grep -qx "checksum=$sum" &&
       ostree --repo="$repo" cat "$ref" /files/bin/apply_extra 2>/dev/null | cmp -s - "$here/apply_extra"; then
        echo "$id: $tag is indexed already"
        continue
    fi

    curl -fsSL -o "$work/app.flatpak" "$(jq -r .browser_download_url <<<"$bundle")"
    flatpak build-import-bundle --no-update-summary --ref="$ref" "$work/bundles" "$work/app.flatpak" >/dev/null
    tree=$work/$id
    ostree --repo="$work/bundles" checkout -U "$ref" "$tree"

    # Keep the listing (what the index needs to show the app and Flatpak
    # needs to put it in menus); everything else links to the tarball's copy.
    files=$tree/files
    rm -f "$files/manifest.json"
    installed=$(du -sb "$files" | cut -f1)
    for f in "$files"/bin/*; do
        rm -rf "$f"
        ln -s "/app/extra/bin/${f##*/}" "$f"
    done
    for d in "$files"/share/*; do
        case ${d##*/} in
            applications|metainfo|appdata|icons|app-info|mime|dbus-1|runtime) ;;
            *) rm -rf "$d"; ln -s "/app/extra/share/${d##*/}" "$d" ;;
        esac
    done
    install -m755 "$here/apply_extra" "$files/bin/apply_extra"
    cat >>"$tree/metadata" <<EOF

[Extra Data]
name=release.tar.gz
checksum=$sum
size=$size
installed-size=$installed
uri=$url
EOF

    flatpak build-export --no-update-summary --disable-sandbox "${sign[@]}" \
        --timestamp="$(jq -r .published_at <<<"$release")" \
        --subject="$id $tag from $url" "$repo" "$tree" stable
    echo "$id: indexed $tag"
    changed=1
    rm -rf "$tree" "$work/app.flatpak"
done <"$here/apps.list"

# An app taken out of apps.list leaves the index; copies already installed
# stay as they are.
for ref in $(ostree --repo="$repo" refs app); do
    id=${ref%%/*}
    if [[ $listed != *" $id "* ]]; then
        ostree --repo="$repo" refs --delete "app/$ref"
        echo "$id: removed"
        changed=1
    fi
done

if [ -n "$changed" ]; then
    flatpak build-update-repo "${sign[@]}" --prune --prune-depth=1 \
        --title="Patrone App Index" --default-branch=stable "$repo"
else
    echo "Nothing changed"
fi
