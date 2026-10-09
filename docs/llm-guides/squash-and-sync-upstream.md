# Squash & Sync Upstream Changes

This guide outlines the "Squash & Sync" strategy used to keep your private branch (`main`) synchronized with the official project upstream (`upstream/main`) while avoiding commit-by-commit conflict resolution and branch history pollution.

---

## Why use Squash & Sync?

When a repository history diverges heavily from the upstream source:
* A standard `git pull` or `git rebase` forces you to resolve conflicts commit-by-commit for every change in between.
* A standard `git merge` pulls in all upstream branch merges, potentially creating "subway track" clutter in your visual git graph.

The Squash & Sync strategy flattens all your local changes into a single block, resets your branch to upstream, and overlays your changes on top. This allows you to resolve all conflicts **exactly once** and keeps your repository graph completely clean.

---

## Step-by-Step Procedure

### 1. Secure Your Local Work
Before touching anything, isolate your current features on a dedicated backup branch so you do not lose any code. If the backup branch already exists, force-recreate it to point to your current `main`:

```bash
git checkout main
git checkout -B my-backup-work
```

### 2. Synchronize Your Mirror Branch
Update your local mirror branch (`sure`) with the latest official changes from the main project:

```bash
git checkout sure
git pull upstream main
```

### 3. Wipe and Reset Main
Move back to your `main` branch and forcefully reset it to perfectly match the updated mirror. This gives you a clean, updated slate:

```bash
git checkout main
git reset --hard sure
```

### 4. Squash Your Work Back on Top
Bring all the changes from your backup branch back onto `main` as a single, uncommitted block:

```bash
git merge --squash my-backup-work
```

### 5. Resolve Conflicts
Since this is a squash merge, you only have to handle conflicts for the final state of the files.

* **To accept all UPSTREAM changes instantly:**
  ```bash
  git checkout --ours . && git add .
  ```
* **To keep all YOUR custom changes instantly:**
  ```bash
  git checkout --theirs . && git add .
  ```
* **Handling Deletions (Critical):**
  If there are files that were deleted in your local work (`my-backup-work`) but modified/present in the upstream, git will report a conflict. If you want these files to remain deleted, resolve the conflict by removing them:
  ```bash
  git rm <file-path>
  ```
  *(Example: Removing conflicting `.github/workflows/pipelock.yml` if you want it deleted).*

---

## Verification & Pre-commit Checks

Before finalizing the merge, you should verify that you have not introduced any unwanted files (such as unexpected workflow files or vendor code).

### 1. Verify Diff Against GitHub Version
Compare your staged index (which is what you are about to commit) against the remote GitHub version of your branch (`origin/main`) to see exactly what you are changing:

```bash
git diff --cached --name-status origin/main
```

* **Workflows check**: If your branch deleted certain workflows (e.g. only keeping `ci.yml` and `publish.yml`), the output of the diff above for the `.github/workflows/` path should be completely empty, meaning the workflows are identical to your previous version.

### 2. Inspect Active Workflows
List files in the workflows directory to verify only the desired files are present:

```bash
ls -la .github/workflows
```

---

## 6. Commit and Push

Once the working tree is clean and the verification checks pass, finalize the merge and force-push to your personal GitHub repository:

```bash
git commit -m "Synchronised upstream changes and flattened local history"
git push origin main --force
```

### 7. Clean Up Backup Branches (Housekeeping)

Once the changes are successfully pushed to your remote repository, you can safely delete the local backup branch to keep your branch list clean:

```bash
git branch -D my-backup-work
```
