# Patrone App Index

The apps Patrone Software offers beyond Ubuntu's archive and Flathub. The
index holds **no apps**: each entry is an app's listing (its name, icon,
description and permissions) and a link to the Linux tarball on its
project's latest GitHub release, with the tarball's checksum. When someone
installs an app in Patrone Software, Flatpak downloads the tarball from the
project's own release, checks it against the checksum and unpacks it. This
is Flatpak's "extra data", which Flathub uses for Spotify and Zoom.

The apps are the Craft apps: storytold's
([github.com/storytold](https://github.com/storytold)) and MailCraft
([UCS-Care-Group/mailcraft](https://github.com/UCS-Care-Group/mailcraft)).

## How it stays current

A GitHub Actions job (`.github/workflows/update.yml`) runs once a day. For
each app in `apps.list` it asks GitHub for the project's latest release; an
app with a new release gets a new entry, read from the release's own
`.flatpak` (for the listing and permissions) and pointing at its tarball.
Installed copies then update as usual. Nothing else changes, so nobody has to
do anything when an app ships a release.

The index is published with GitHub Pages from the `gh-pages` branch, at
`https://billsecond.github.io/patrone-app-index/repo/`, and signed with the
key whose public half is in `patrone-app-index.flatpakrepo`. The private key
is the repository secret `INDEX_GPG_KEY`.

## Adding or removing an app

Edit `apps.list`: one line per app, with its GitHub project, its app ID and
the prefix of its release files. The project's releases must carry
`<prefix>-<version>-linux-x86_64.tar.gz` and
`<prefix>-<version>-linux-x86_64.flatpak`, as the Craft apps' releases do.
Pushing the change runs the job. An app taken off the list leaves the index;
copies already installed stay, without updates.

## Building it by hand

```sh
./build-index.sh repo            # unsigned, for testing
flatpak remote-add --user --no-gpg-verify test-index "file://$PWD/repo"
```

Needs `curl`, `jq`, `ostree` and `flatpak`.
