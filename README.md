# PDF Renamer & Metadata Extractor

A macOS automation tool that watches a folder for new PDF files, extracts
academic citation metadata using the OpenAI API, renames each PDF, moves it to
your final library folder, and creates a matching `.ris` citation file.

This is ideal for people who download many PDFs and want automatic
bibliographic organization.

[Demo video](https://www.youtube.com/watch?v=J2odEjKz3Og)

---

## Features

- Extracts metadata from PDFs:
  - first author
  - all authors
  - title
  - journal
  - year
  - volume, issue, pages
  - DOI
- Renames PDFs into citation-friendly names
- Moves renamed PDFs to a letter-based subfolder in the final destination folder
- Writes an `.ris` file for reference managers
- Uses macOS `launchd` to run automatically on folder changes
- Drains multi-file drops by rescanning until no unprocessed PDFs remain
- Falls back to a safe filename if metadata is missing
- Skips reprocessing the same source file using SHA-256 tracking

---

## Dependencies

Required:

- macOS
- `pdftotext` (from poppler)
- `jq`
- `curl`
- an OpenAI API key

Install dependencies via Homebrew:

```bash
brew install poppler jq
```

---

## Security Model (Important)

The API key is stored in macOS Keychain, not in the LaunchAgent plist.

- Do not place `OPENAI_API_KEY` directly inside any plist.
- Do not commit keys to GitHub.
- If a key is ever shown in logs/chat/screenshots, revoke it immediately.

---

## Configuration

### 1. Edit user settings in `pdf_renamer.sh`

Update the top section of the script:

```bash
WATCHDIR="$HOME/WatchFolder"
FINALDIR="$HOME/ProcessedPapers"
PDFTOTEXT="/usr/local/bin/pdftotext"
JQ="/opt/anaconda3/bin/jq"
CURL="/opt/anaconda3/bin/curl"
```

Notes:

- `WATCHDIR`: folder where you drop incoming PDFs.
- `FINALDIR`: base destination folder for renamed PDFs. The script creates subfolders `A` through `Z` under this folder and places each PDF into the subfolder matching the first letter of the output filename.
- `PDFTOTEXT`, `JQ`, `CURL`: absolute paths are required under `launchd`.
- The script accepts both `.pdf` and `.PDF` files.

Find tool paths with:

```bash
which pdftotext
which jq
which curl
```

### 2. Save your OpenAI key into Keychain

Create or rotate your key at:

[OpenAI API keys](https://platform.openai.com/api-keys)

Store the key in Keychain (you will be prompted securely for the value):

```bash
security add-generic-password -a "$USER" -s "pdf_renamer_openai_api_key" -U -w
```

If terminal paste is unreliable for long keys, use the included helper instead:

1. Open Terminal and change into the repo folder:

```bash
cd /Users/rnj/DWork/GitHub/pdf_renamer
```

1. Create a local file containing only the raw key on a single line:

```bash
printf '%s\n' 'paste-your-full-key-here' > .openai_api_key.local
```

Replace `paste-your-full-key-here` with the actual key value from the OpenAI dashboard.

Important:

- Keep the surrounding single quotes in the command.
- Do not add `OPENAI_API_KEY=`.
- Do not add extra spaces before or after the key.
- The file should contain exactly one line: just the key.

1. Optionally verify the file contents in a safer way before storing it:

```bash
wc -c .openai_api_key.local
shasum -a 256 .openai_api_key.local
```

`wc -c` includes the trailing newline written by `printf`, so the file byte count will usually be the key length plus 1.

1. Run the helper script:

```bash
./set_openai_key.sh
```

The script will:

- read the key from `.openai_api_key.local`
- print a short preview, length, and SHA-256 of the source key
- store it in Keychain
- read it back from Keychain
- print the stored preview, length, and SHA-256
- fail if the stored value is not an exact match

1. If the source and stored lengths and SHA-256 match, Keychain setup is complete.

1. Optionally delete the local file after successful import:

```bash
rm .openai_api_key.local
```

It prints only a short preview plus hash and length, not the full secret.

Verify it exists:

```bash
security find-generic-password -a "$USER" -s "pdf_renamer_openai_api_key" -w >/dev/null && echo "Keychain OK"
```

### 3. Configure `com.example.pdfrenamer.plist`

1. Rename it to your own label (example: `com.yourname.pdfrenamer.plist`).
1. Update `Label`, `ProgramArguments` path to your repo script, and `WatchPaths` folder.
1. Move it to `~/Library/LaunchAgents/`.

Do not add an `EnvironmentVariables` key for API secrets.

---

## Installation Using macOS `launchd`

### 1. Install the script

```bash
chmod +x /Users/rnj/DWork/GitHub/pdf_renamer/pdf_renamer.sh
xattr -d com.apple.quarantine /Users/rnj/DWork/GitHub/pdf_renamer/pdf_renamer.sh 2>/dev/null || true
```

Use the repo script as the canonical runtime copy so edits and execution stay aligned.

### 2. Install the plist

```bash
mkdir -p "$HOME/Library/LaunchAgents"
cp com.example.pdfrenamer.plist "$HOME/Library/LaunchAgents/com.yourname.pdfrenamer.plist"
```

Edit that copied plist for your paths/label, and point `ProgramArguments` at `/Users/rnj/DWork/GitHub/pdf_renamer/pdf_renamer.sh` or your equivalent repo path.

### 3. Load and start the service

```bash
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.yourname.pdfrenamer.plist" 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.yourname.pdfrenamer.plist"
launchctl kickstart -k gui/$(id -u)/com.yourname.pdfrenamer
```

### 4. Stop/unload the service

```bash
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.yourname.pdfrenamer.plist"
```

---

## Runtime Behavior

1. Drop a PDF into your watch folder.
2. Script extracts text and asks the OpenAI API for citation metadata.
3. Script renames PDF as `AuthorBlock_Year_Title.pdf`.
4. Script moves PDF to a subfolder inside your final folder, based on the first letter of the output filename.
5. Script writes a matching `.ris` file in the watch folder.
6. While one run is active, later watch events exit quickly by design; the active run rescans the watch folder until no unprocessed PDFs remain.

Example:

- `Moodie_2025_Brain-maps-of-general-cognitive-functioning.pdf`
  is moved to:
  `FINALDIR/M/`

If the output filename does not start with a letter, the script uses `FINALDIR/_/`.

If metadata is poor or missing:

- The script now uses a fallback name, for example:
  - `Unknown_XXXX_original-filename.pdf`

Duplicate protection:

- Processed source files are tracked in:
  - `WATCHDIR/.pdf_renamer_processed.sha256`
- If the same file hash appears again, it is skipped.

Concurrency protection:

- The script uses `WATCHDIR/.pdf_renamer.lock` so only one instance processes the queue at a time.
- If a second `launchd` trigger fires while the first run is active, the second run exits immediately and the active run continues draining the folder.

---

## Troubleshooting

Check LaunchAgent status:

```bash
launchctl print gui/$(id -u)/com.yourname.pdfrenamer | rg "state =|runs =|last exit code"
```

For a running agent, `program =` should point at your repo copy of `pdf_renamer.sh`.

Check logs:

```bash
tail -n 100 /tmp/pdf_renamer_stdout.log
tail -n 100 /tmp/pdf_renamer_stderr.log
```

Common issue: missing key in Keychain.

If you see a message like:

`Missing OpenAI key in Keychain (service: pdf_renamer_openai_api_key, account: your_user)`

run the Keychain setup command again.

---

## License

Released under the MIT License. See `LICENSE.md` for details.
