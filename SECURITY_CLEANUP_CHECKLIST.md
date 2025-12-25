# Security Cleanup Checklist - Before Making Repo Public

## Critical Issues to Fix

### 1. Remove Hardcoded Passwords from Environment Files

**Files with actual credentials (MUST REMOVE FROM GIT):**
- [ ] `.env.local` - contains `PGPASSWORD=fucker` and `ADMIN_API_KEY=shitfuck`
- [ ] `.env.production` - contains `PGPASSWORD=fucker` and `ADMIN_API_KEY=shitfuck`
- [ ] `api/.env.local` - contains `PGPASSWORD=fucker` and `ADMIN_API_KEY=shitfuck`
- [ ] `api/.env.production` - contains `PGPASSWORD=fucker` and `ADMIN_API_KEY=shitfuck`

**Action Plan:**
```bash
# 1. Remove from git history (IMPORTANT!)
git rm --cached .env.local .env.production
git rm --cached api/.env.local api/.env.production

# 2. Add to .gitignore (already done, but verify)
echo "" >> .gitignore
echo "# Never track actual environment configs with real credentials" >> .gitignore
echo "/.env.local" >> .gitignore
echo "/.env.production" >> .gitignore
echo "/api/.env.local" >> .gitignore
echo "/api/.env.production" >> .gitignore

# 3. Commit the removal
git add .gitignore
git commit -m "Remove environment files with real credentials from git tracking"

# 4. IMPORTANT: Purge from git history
# Use BFG Repo Cleaner or git-filter-repo to remove from all commits
# Download BFG: https://rtyley.github.io/bfg-repo-cleaner/
java -jar bfg.jar --delete-files '.env.local' .
java -jar bfg.jar --delete-files '.env.production' .
git reflog expire --expire=now --all && git gc --prune=now --aggressive
```

### 2. Remove Hardcoded Passwords from Code Files

- [ ] `api/test_db.py` line 7 - hardcoded password
  ```python
  # Change from:
  password="fucker",
  # To:
  password=os.getenv('PGPASSWORD', 'your_local_dev_password'),
  ```

- [ ] `scripts/backfill_workout_hash.py` line 16 - hardcoded password
  ```python
  # Change from:
  DB_PASSWORD = "fucker"
  # To:
  DB_PASSWORD = os.getenv('PGPASSWORD', '')
  ```

### 3. Clean Up Documentation Files

**Files with embedded passwords (for examples/documentation):**
- [ ] `docs/LOCAL_DEV_SETUP.md` - lines 61, 68, 112, 183
- [ ] `docs/MIGRATION_UBUNTU_TO_MAC.md` - line 85
- [ ] `docs/SETUP_ISSUES_AND_SOLUTIONS.md` - lines 142, 363, 634, 642
- [ ] `docs/REFACTORING_ROADMAP.md` - lines 120, 484, 491
- [ ] `docs/DATABASE_CLEANUP_SUMMARY.md` - line 123
- [ ] `ENVIRONMENT_SETUP.md` - line 49
- [ ] All files in `docs/archive/` directory
- [ ] All files in `scripts/obsolete/` directory

**Action:** Replace actual password with placeholder:
```bash
# Find and replace in docs
find docs -type f -name "*.md" -exec sed -i '' 's/PGPASSWORD=fucker/PGPASSWORD=your_secure_password/g' {} \;
find docs -type f -name "*.md" -exec sed -i '' "s/password='fucker'/password='your_secure_password'/g" {} \;
find docs -type f -name "*.md" -exec sed -i '' 's/ADMIN_API_KEY=shitfuck/ADMIN_API_KEY=your_secure_api_key/g' {} \;

# Same for root markdown files
sed -i '' 's/PGPASSWORD=fucker/PGPASSWORD=your_secure_password/g' ENVIRONMENT_SETUP.md

# Fix Python scripts
sed -i '' 's/DB_PASSWORD = "fucker"/DB_PASSWORD = os.getenv("PGPASSWORD", "")/g' scripts/backfill_workout_hash.py
```

### 4. Remove Internal IP Addresses

**Files containing internal IP: 192.168.68.25**

This IP appears in 83 files. Most are in:
- Documentation (safe - just examples)
- `.claude/settings.local.json` ✅ **TRACKED IN GIT** - should not be public
- Old scripts in `scripts/obsolete/` - safe, just examples

**Actions:**
- [ ] Remove `.claude/settings.local.json` from git (contains IP + password)
  ```bash
  git rm --cached .claude/settings.local.json
  echo "/.claude/settings.local.json" >> .gitignore
  ```

- [ ] Replace IP in docs with placeholder
  ```bash
  find docs -type f -name "*.md" -exec sed -i '' 's/192\.168\.68\.25/your-server-ip/g' {} \;
  ```

### 5. Verify .gitignore is Correct

Current `.gitignore` already excludes `.env` files, but we need to ensure the actual environment configs are never tracked:

```gitignore
# Environment files - actual configs (NEVER COMMIT)
/.env
/.env.local
/.env.production
/api/.env
/api/.env.local
/api/.env.production

# Claude settings (contains passwords + IPs)
/.claude/settings.local.json

# Only track templates
!.env.example
!api/.env.example
```

### 6. Change Actual Passwords Before Making Public

Even after removing from git, you should change the actual passwords:

- [ ] Change PostgreSQL password from "fucker"
  ```bash
  # On production server
  psql -U postgres -c "ALTER USER runmap_user WITH PASSWORD 'new_secure_password';"

  # Update local database
  psql -U postgres -h localhost -c "ALTER USER runmap_user WITH PASSWORD 'new_local_password';"
  ```

- [ ] Change admin API key from "shitfuck"
  - Generate new random API key
  - Update in your local `.env.production` and `.env.local` (not tracked)
  - Update on production server

### 7. Verify Clean Repository

Before pushing public:

```bash
# Check what's tracked
git ls-files | grep -E '\.(env|json)$'
# Should only show .example files, not actual .env files

# Check for passwords in tracked files
git grep -i 'fucker\|shitfuck' -- ':(exclude)*.md' ':(exclude)docs/'
# Should return nothing

# Check git history for leaked credentials
git log --all --full-history --source --find-object=.env.production
# Should be empty after BFG cleanup
```

## Quick Sanitization Script

Run this script to automate most of the cleanup:

```bash
#!/bin/bash
# sanitize_repo.sh - Remove sensitive data before making public

set -e

echo "🔒 Sanitizing repository..."

# 1. Remove environment files from git
echo "Removing .env files from git tracking..."
git rm --cached .env.local .env.production api/.env.local api/.env.production 2>/dev/null || true
git rm --cached .claude/settings.local.json 2>/dev/null || true

# 2. Update .gitignore
echo "Updating .gitignore..."
cat >> .gitignore << 'EOF'

# Never track actual environment configs with real credentials
/.env.local
/.env.production
/api/.env.local
/api/.env.production
/.claude/settings.local.json
EOF

# 3. Replace passwords in documentation
echo "Sanitizing documentation..."
find docs -type f -name "*.md" -exec sed -i '' 's/PGPASSWORD=fucker/PGPASSWORD=your_secure_password/g' {} \;
find docs -type f -name "*.md" -exec sed -i '' "s/password='fucker'/password='your_secure_password'/g" {} \;
find docs -type f -name "*.md" -exec sed -i '' 's/ADMIN_API_KEY=shitfuck/ADMIN_API_KEY=your_secure_api_key/g' {} \;
sed -i '' 's/PGPASSWORD=fucker/PGPASSWORD=your_secure_password/g' ENVIRONMENT_SETUP.md

# 4. Replace IP addresses
echo "Replacing internal IPs..."
find docs -type f -name "*.md" -exec sed -i '' 's/192\.168\.68\.25/your-server-ip/g' {} \;

# 5. Fix Python scripts
echo "Fixing hardcoded passwords in Python..."
sed -i '' 's/DB_PASSWORD = "fucker"/DB_PASSWORD = os.getenv("PGPASSWORD", "")/g' scripts/backfill_workout_hash.py

# 6. Commit changes
echo "Committing sanitization..."
git add .gitignore docs/ ENVIRONMENT_SETUP.md scripts/backfill_workout_hash.py
git commit -m "Security: Remove sensitive credentials and IPs before making public

- Remove .env files with real passwords from git tracking
- Replace hardcoded passwords in docs with placeholders
- Replace internal IP addresses with placeholders
- Fix hardcoded passwords in Python scripts
"

echo "✅ Repository sanitized!"
echo ""
echo "⚠️  NEXT STEPS:"
echo "1. Use BFG Repo Cleaner to purge .env files from git history"
echo "2. Change actual passwords on production and local databases"
echo "3. Generate new admin API key"
echo "4. Verify with: git grep -i 'fucker\\|shitfuck' -- ':(exclude)*.md' ':(exclude)docs/'"
echo "5. Create fresh .env.local and .env.production with new credentials (not tracked)"
```

## Post-Cleanup Verification

After sanitization, verify:

- [ ] No `.env` files tracked: `git ls-files | grep '\.env\.'` returns only `.example` files
- [ ] No passwords in code: `git grep -i 'password.*fucker'` returns nothing (except maybe comments)
- [ ] No API keys in code: `git grep -i 'shitfuck'` returns nothing (except docs)
- [ ] Git history clean (after BFG): `git log --all --oneline | head -20`
- [ ] Working local copy has new `.env.local` with new passwords (not tracked)

## Creating Public Version

Consider creating a public fork rather than making the current repo public:

1. Create new empty repository on GitHub (public)
2. Clone current sanitized repo to new location
3. Add public repo as new remote
4. Force push cleaned history
5. Keep original private repo as backup

This ensures complete isolation from any history of leaked credentials.

## Notes

- The password "fucker" appears in 83+ locations across the repo
- The admin API key "shitfuck" appears in all environment files
- Internal IP 192.168.68.25 appears in 83+ files (mostly docs/examples)
- `.claude/settings.local.json` contains both passwords and IPs - must never be public
