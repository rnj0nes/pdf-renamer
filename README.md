# PDF Renamer & Metadata Extractor

A macOS automation tool that watches a folder for new PDF files, extracts
academic citation metadata using the OpenAI API, renames the PDF according to
the extracted metadata, and generates a matching `.ris` citation file.

This is ideal for people who download many PDFs and want automatic
bibliographic organization.

https://www.youtube.com/watch?v=J2odEjKz3Og


---

## Features

- Automatically extracts metadata from PDFs:
  - First author
  - Full author list
  - Title
  - Journal
  - Year
  - Volume, Issue, Pages
  - DOI
- Renames PDFs using a consistent, citation-friendly filename structure
- Moves processed PDFs to a final destination folder
- Writes an `.ris` citation file for reference managers
- Runs automatically using macOS `launchd` — no app needs to stay open

---

## Dependencies

You must have the following installed:

- `pdftotext` from poppler
- `jq`
- `curl`
- macOS
- An OpenAI API key

Install dependencies via Homebrew:

```bash
brew install poppler jq
```

---

## Configuration


### OpenAI API Key
To use this tool, you must create an OpenAI API key.

1. Visit the API Keys page:  
   **https://platform.openai.com/api-keys**

2. Click **Create new secret key**.  
3. Copy the key and add it to your environment (see instructions below).  

For security:  
- Treat your API key like a password.  
- Never commit it to GitHub.  
- Rotate or revoke keys anytime in the same dashboard.


### Edit the user settings at the top of `pdf_renamer.sh`:

Configure Your Local Paths (Required) - Before running the script, you must edit the user-specific settings at the top of pdf_renamer.sh. These tell the script where incoming PDFs will appear (and which folder to watch), where renamed PDFs should be moved (need to move them to avoid infinite loops), and where your system stores the required command-line tools.
  
Open the script `pdf_renamer.sh` in any text editor and locate this block:

```bash
WATCHDIR="$HOME/WatchFolder"
FINALDIR="$HOME/ProcessedPapers"
PDFTOTEXT="/usr/local/bin/pdftotext"
JQ="/opt/anaconda3/bin/jq"
CURL="/opt/anaconda3/bin/curl"
```

Below is what each variable means and how to configure it.

**WATCHDIR** — Folder to Monitor for New PDFs. This folder is where you will drop PDFs that you want automatically renamed. You may pick any folder (but avoid iCloud/Dropbox). In my set-up I used `~/Dwork/sandbox`.

**FINALDIR** — Folder where renamed PDFs will be stored. After a PDF is renamed, it will be moved out of the watch folder to prevent infinite loops. In my set-up I use `~/Library/CloudStorage/Dropbox/Reprint`. 

**PDFTOTEXT** — Absolute Path to pdftotext. You installed `poppler` above, right? The script must use the full path, because launchd does not inherit your interactive shell PATH.

Find your location by typing at the terminal:

```bash
which pdftotext
```

**JQ** — Absolute Path to jq. Again, full path required. Find it using `which` as with `pdftotext`.

**CURL** — Absolute Path to curl. Use `which curl` if you don't know.

Once these variables are correct, the script will know where to pick up PDFs, where to move renamed PDFs, and how to find the required external programs even inside launchd.

### Edit the user settings at the top of `com.example.pdfrenamer.plist`:

Rename the plist file to match your domain and script name, e.g., `com.yourname.pdfrenamer.plist` (mine is actually `com.rnj.pdfrenamer.plist`, for example). 

Move the plist file to `~/Library/LaunchAgents/`.

Configure Your Local Paths (Required) - Before using the launchd service, you must edit the user-specific settings at the top of `com.example.pdfrenamer.plist`. These tell launchd where to find the script and your environment variables.

Include your OpenAI API key in the plist as an environment variable.


---

## Installation Using macOS and `launchd`

### Install the Script (Ownership & Permissions)

Once you have edited the top section of `pdf_renamer.sh`, you must put it in a safe, permanent location; give yourself ownership; mark it as executable. Follow these steps in Terminal:

1. Choose an installation location. I recommend placing the script in your home directory:

```bash
mv pdf_renamer.sh "$HOME/pdf_renamer.sh"
```

2. Ensure you own the file. This prevents permission issues when launchd runs it.


```bash
sudo chown $USER "$HOME/pdf_renamer.sh"
```

3. Make the script executable. This is required, otherwise macOS cannot launch it.
   
```bash
chmod +x "$HOME/pdf_renamer.sh"
```

4. Gatekeeper quarantine (important!). If the script was downloaded from GitHub, macOS may mark it as “suspicious” and refuse to run it under launchd. Remove the quarantine attribute:

```bash
xattr -d com.apple.quarantine "$HOME/pdf_renamer.sh"
```


### Load the service

```bash
launchctl load ~/Library/LaunchAgents/com.example.pdfrenamer.plist
```

### Stop the service (if needed)

```bash
launchctl unload ~/Library/LaunchAgents/com.example.pdfrenamer.plist
```

---

## Folder Workflow

1. Drop a PDF into your **Watch Folder**
2. Script extracts metadata using the OpenAI API
3. Script renames the PDF → `"Author1-Author2_2024_Title.pdf"`
4. Script moves the renamed PDF into **ProcessedPapers**
5. Script writes a `.ris` file into the Watch Folder

## License

Released under the MIT License. See `LICENSE` for details.

Copyright (c) 2025 Richard N. Jones

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the “Software”), to deal
in the Software without restriction, including without limitation the rights  
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell  
copies of the Software, and to permit persons to whom the Software is  
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in  
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR  
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE  
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER  
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING  
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER  
DEALINGS IN THE SOFTWARE.
