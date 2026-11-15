# template

The starting point for a new penguincam repository. After you stamp it, set
the title, this sentence, `repo` in the justfile and the license.

## Start

```sh
gh repo fork penguincam/<repo> --fork-name <repo>-contrib --clone
cd <repo>-contrib
just fork-setup <your-login>
just hooks-install
```

## Tasks

| Task | Command |
|---|---|
| List recipes | `just` |
| Compare hooks with the organization copy | `just hooks-check` |
| Test the hooks | `just hooks-test` |
| Check this README | `just readme-check` |
| Run the repository contract test | `just contract-test` |

## Related

- [.github](https://github.com/penguincam/.github): contributing guide, security policy and git hooks.

## Contributing

Read the [contributing guide](https://github.com/penguincam/.github/blob/main/CONTRIBUTING.md).
Pull requests go from a branch on your fork into `dev`.

## License

Name the license here and add its LICENSE file.
