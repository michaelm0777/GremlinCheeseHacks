# Add this project to GitHub

## 1. Create a new repo on GitHub

1. Open **https://github.com/new**
2. Set **Repository name** (e.g. `Testinging` or `Gremlin`).
3. Choose **Public** or **Private**.
4. **Do not** add a README, .gitignore, or license (this project already has content).
5. Click **Create repository**.

## 2. Add the remote and push

In Terminal, from this project folder:

```bash
cd /Users/michaelmeng/Documents/Projects/Testinging

# Add your new GitHub repo as the remote (replace YOUR_USERNAME and YOUR_REPO with your values)
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO.git

# Stage and commit any uncommitted changes
git add -A
git status   # optional: review what will be committed
git commit -m "Add Firebase two-device lock flow and Family Controls"

# Push to GitHub (use main or master depending on your default branch)
git push -u origin main
```

If your default branch is `master` instead of `main`:

```bash
git push -u origin master
```

## 3. Optional: hide Firebase config in public repos

If the repo is **public**, avoid committing `GoogleService-Info.plist` (it contains your API key). In `.gitignore`, uncomment these two lines:

```
# GoogleService-Info.plist
# **/GoogleService-Info.plist
```

Then remove the file from git (keeps it on disk):

```bash
git rm --cached GoogleService-Info.plist Testinging/GoogleService-Info.plist 2>/dev/null; git commit -m "Stop tracking GoogleService-Info.plist"
```

Each developer (or CI) adds their own `GoogleService-Info.plist` from the Firebase Console.
