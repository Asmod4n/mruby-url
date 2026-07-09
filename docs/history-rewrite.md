# History rewrite (2026-07-05)

`main` was force-pushed on 2026-07-05 to scrub tool-generated session URLs
from old commit messages; every commit SHA from mid-history onward changed. A
plain `git pull` on a clone made before then will fail or produce a bogus
merge. Re-sync with:

```sh
git fetch origin
git checkout main
git reset --hard origin/main
```

Local branches made before the rewrite need

```sh
git rebase --onto origin/main 4a245f622f82b4ce22f69303bab8122a0b8d4ba2 <your-branch>
```

(`4a245f622f82b4ce22f69303bab8122a0b8d4ba2` was main's pre-rewrite head;
substitute the older commit your branch actually forked from if it predates
it — or just re-clone). CI now rejects any push that reintroduces such URLs.
