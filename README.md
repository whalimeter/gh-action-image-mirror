# Docker Image Mirror

This [project] implements a [script] and GitHub [action] that will mirror images
between registries. The default is to mirror to the GHCR. For proper operation,
you will have to login both at the source and destination registry. When running
as an action and against the GHCR, you will also have to give your workflow the
permission to write packages.

The [script], also used by the [action] has good defaults. When passed an image
with a tag, it will only mirror that image. Otherwise, it will only pick up
images with sharp semantic versions in their tags, and is then able to restrict
to a range of versions. The [script] supports both multi-platform and
single-platform images.

The following example would mirror the Alpine images from the Docker Hub under
the repository that it is running at. It requires that a secret called
`DOCKERHUB_TOKEN` is available. Only sharp versions and versions greater or
equal to `3.18` will be mirrored.

```yaml
name: mirror

on:
  workflow_dispatch:

jobs:
  mirror:
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      -
        name: Login to Docker Hub
        uses: docker/login-action@v2
        with:
          username: efrecon
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      -
        name: Login to GHCR
        uses: docker/login-action@v2
        with:
          registry: ghcr.io
          username: ${{ github.repository_owner }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: alpine
        uses: whalimeter/gh-action-image-mirror@main
        with:
          image: alpine
          minver: "3.18"
```

  [project]: https://github.com/efrecon/gh-mirror-docker-mirror
  [script]: ./mirror.sh
  [action]: action.yml

For more information about the action check its [inputs][action].

## Development

The `reg-tags` package is added as a subtree, as it is not possible to use
submodules in GitHub actions (their code is not automatically checked out from
calling workflows). To add the sub-project, the following command was issued:

```shell
git subtree add --prefix reg-tags https://github.com/efrecon/reg-tags.git master --squash
```
