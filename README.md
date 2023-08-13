# gh-action-docker-mirror

## Development

The `reg-tags` package is added as a subtree, as it is not possible to use
submodules in GitHub actions (their code is not automatically checked out from
calling workflows). To add the sub-project, the following command was issued:

```shell
git subtree add --prefix reg-tags https://github.com/efrecon/reg-tags.git master --squash
```
