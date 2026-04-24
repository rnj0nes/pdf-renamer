#!/bin/bash

###########################################################
# USER SETTINGS
###########################################################
WATCHDIR="/Users/rnj/DWork/sandbox"
FINALDIR="/Users/rnj/Library/CloudStorage/Dropbox/Reprint"

PDFTOTEXT="/usr/local/bin/pdftotext"
JQ="/opt/anaconda3/bin/jq"
CURL="/opt/anaconda3/bin/curl"

KEYCHAIN_SERVICE="pdf_renamer_openai_api_key"
KEYCHAIN_ACCOUNT="${USER:-$(/usr/bin/id -un)}"
OPENAI_API_KEY=$(/usr/bin/security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)

if [[ -z "$OPENAI_API_KEY" ]]; then
    echo "Missing OpenAI key in Keychain (service: $KEYCHAIN_SERVICE, account: $KEYCHAIN_ACCOUNT)" >&2
    exit 1
fi

LOCKDIR="$WATCHDIR/.pdf_renamer.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

PROCESSED_DB="$WATCHDIR/.pdf_renamer_processed.sha256"
touch "$PROCESSED_DB"

while true; do
    shopt -s nullglob
    PDF_FILES=("$WATCHDIR"/*.pdf "$WATCHDIR"/*.PDF)
    shopt -u nullglob

    [[ ${#PDF_FILES[@]} -eq 0 ]] && exit 0

    PENDING_FOUND=0

for PDF in "${PDF_FILES[@]}"; do
    [[ -f "$PDF" ]] || continue

    DIR=$(dirname "$PDF")
    BASE=$(basename "$PDF")
    BASE_NO_EXT="${BASE%.*}"
    AUTHOR_BLOCK=""
    AUTHOR=""
    AUTH_LAST_LIST='[]'
    AUTHORS_FULL=""
    YEAR="XXXX"
    TITLE=""
    FULL_TITLE=""
    JOURNAL=""
    VOLUME=""
    ISSUE=""
    PAGES=""
    DOI=""
    API_ERROR=""
    CLEAN=""
    META=""

    PDF_HASH=$(/usr/bin/shasum -a 256 "$PDF" 2>/dev/null | awk '{print $1}')
    [[ -z "$PDF_HASH" ]] && continue

    if grep -Fqx "$PDF_HASH" "$PROCESSED_DB"; then
        continue
    fi

    PENDING_FOUND=1

    ###########################################################
    # EXTRACT TEXT
    ###########################################################
    PDF_TEXT=$("$PDFTOTEXT" "$PDF" - 2>/dev/null)

    ###########################################################
    # SYSTEM & USER MESSAGES (Unicode-safe, jq-safe)
    ###########################################################
    SYSTEM_MSG="Extract academic article metadata. Return ONLY raw JSON. No markdown. No code fences.

Required keys:
- first_author_last
- all_authors_last
- authors_full
- year
- title
- journal
- volume
- issue
- pages
- doi

Also return a key called \"ris_authors\":
This must be a list of RIS-formatted author strings, each like:
\"Lastname, First MiddleInitials\".

Rules:
- Extract names ONLY from the PDF.
- Reconstruct names even if split across lines.
- Remove academic degrees (PhD, MD, ScD, etc.).
- Preserve hyphens in surnames (e.g., Pascual-Leone).
"

    USER_MSG="Extract metadata and also return a fully formatted list called \"ris_authors\".
Each element must be a valid RIS author string formatted as:
\"Lastname, First Middle\".

Do NOT include academic degrees.
Do NOT guess names.
Do NOT output markdown.

TEXT FROM PDF:
$PDF_TEXT
"

    ###########################################################
    # BUILD JSON CLEANLY (NO ESCAPING REQUIREMENTS)
    ###########################################################
    JSON=$("$JQ" -n \
      --arg sys "$SYSTEM_MSG" \
      --arg usr "$USER_MSG" \
      '
{
  "model": "gpt-4o-mini",
  "temperature": 0,
  "messages": [
    { "role": "system", "content": $sys },
    { "role": "user",   "content": $usr }
  ]
}
'
    )

    ###########################################################
    # CALL OPENAI API
    ###########################################################
    RESPONSE=$("$CURL" -s https://api.openai.com/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -d "$JSON")

    echo "$RESPONSE" > /tmp/gpt_response.json

    ###########################################################
    # CHECK FOR API ERRORS
    ###########################################################
    API_ERROR=$(echo "$RESPONSE" | "$JQ" -r '.error.message // empty')
    if [[ -n "$API_ERROR" ]]; then
        echo "API Error: $API_ERROR" >&2
        echo "Source: $BASE - will attempt filename parsing fallback" >&2
        AUTHOR=""
        AUTH_LAST_LIST='[]'
        AUTHORS_FULL=""
        YEAR="XXXX"
        TITLE=""
        FULL_TITLE=""
        JOURNAL=""
        VOLUME=""
        ISSUE=""
        PAGES=""
        DOI=""
    else
        ###########################################################
        # CLEAN ANY CODE FENCES (GPT should not produce these)
        ###########################################################
        CLEAN=$(echo "$RESPONSE" | sed 's/```json//g' | sed 's/```//g')

        MESSAGE_CONTENT=$(echo "$CLEAN" | "$JQ" -r '.choices[0].message.content // empty')
        if [[ -z "$MESSAGE_CONTENT" ]]; then
            echo "Warning: Empty API response for $BASE" >&2
        fi

        META='.choices[0].message.content | fromjson |'

        ###########################################################
        # PARSE METADATA (with error handling)
        ###########################################################
        AUTHOR=$(echo "$CLEAN" | "$JQ" -r "$META .first_author_last" 2>/dev/null)
        AUTH_LAST_LIST=$(echo "$CLEAN" | "$JQ" -r "$META .all_authors_last" 2>/dev/null)
        AUTHORS_FULL=$(echo "$CLEAN" | "$JQ" -r "$META .authors_full" 2>/dev/null)

        YEAR=$(echo "$CLEAN" | "$JQ" -r "$META .year" 2>/dev/null)
        TITLE=$(echo "$CLEAN" | "$JQ" -r "$META .title" 2>/dev/null)
        FULL_TITLE="$TITLE"
        JOURNAL=$(echo "$CLEAN" | "$JQ" -r "$META .journal" 2>/dev/null)
        VOLUME=$(echo "$CLEAN" | "$JQ" -r "$META .volume" 2>/dev/null)
        ISSUE=$(echo "$CLEAN" | "$JQ" -r "$META .issue" 2>/dev/null)
        PAGES=$(echo "$CLEAN" | "$JQ" -r "$META .pages" 2>/dev/null)
        DOI=$(echo "$CLEAN" | "$JQ" -r "$META .doi" 2>/dev/null)
    fi

    ###########################################################
    # FALLBACKS
    ###########################################################
    [[ "$YEAR" == "null" || -z "$YEAR" ]] && YEAR="XXXX"
    [[ "$AUTHOR" == "null" ]] && AUTHOR=""
    [[ "$TITLE" == "null" ]] && TITLE=""
    [[ "$JOURNAL" == "null" ]] && JOURNAL=""
    [[ "$VOLUME" == "null" ]] && VOLUME=""
    [[ "$ISSUE" == "null" ]] && ISSUE=""
    [[ "$PAGES" == "null" ]] && PAGES=""
    [[ "$DOI" == "null" ]] && DOI=""

    ###########################################################
    # INTELLIGENT FALLBACK LOGIC
    ###########################################################
    if [[ -z "$AUTHOR" && "$YEAR" == "XXXX" && -z "$TITLE" ]]; then
        echo "API metadata empty for $BASE, attempting filename parse..." >&2

        if [[ "$BASE_NO_EXT" =~ ^([A-Za-z-]+)---([0-9]{4})---(.+)$ ]]; then
            PARSED_AUTHOR="${BASH_REMATCH[1]}"
            PARSED_YEAR="${BASH_REMATCH[2]}"
            PARSED_TITLE="${BASH_REMATCH[3]}"

            AUTH_LAST_LIST="[\"$PARSED_AUTHOR\"]"
            YEAR="$PARSED_YEAR"
            TITLE="$PARSED_TITLE"
            FULL_TITLE="$PARSED_TITLE"

            echo "Parsed from filename: $PARSED_AUTHOR, $PARSED_YEAR, $PARSED_TITLE" >&2
        elif [[ "$BASE_NO_EXT" =~ ^([A-Za-z-]+)_([0-9]{4})_(.+)$ ]]; then
            PARSED_AUTHOR="${BASH_REMATCH[1]}"
            PARSED_YEAR="${BASH_REMATCH[2]}"
            PARSED_TITLE="${BASH_REMATCH[3]}"

            AUTH_LAST_LIST="[\"$PARSED_AUTHOR\"]"
            YEAR="$PARSED_YEAR"
            TITLE="$PARSED_TITLE"
            FULL_TITLE="$PARSED_TITLE"

            echo "Parsed from filename: $PARSED_AUTHOR, $PARSED_YEAR, $PARSED_TITLE" >&2
        else
            echo "No parseable structure in filename, using Unknown fallback" >&2
            AUTHOR_BLOCK="Unknown"
            TITLE="$BASE_NO_EXT"
            FULL_TITLE="$TITLE"
            AUTH_LAST_LIST='[]'
        fi
    fi

    ###########################################################
    # FILENAME AUTHOR BLOCK
    ###########################################################
    if [[ "$AUTHOR_BLOCK" != "Unknown" ]]; then
        NUMAUTH=$(echo "$AUTH_LAST_LIST" | "$JQ" 'length' 2>/dev/null)

        if [[ "$NUMAUTH" -eq 1 ]]; then
            AUTHOR_BLOCK=$(echo "$AUTH_LAST_LIST" | "$JQ" -r '.[0]' 2>/dev/null)
        elif [[ "$NUMAUTH" -eq 2 ]]; then
            A1=$(echo "$AUTH_LAST_LIST" | "$JQ" -r '.[0]' 2>/dev/null)
            A2=$(echo "$AUTH_LAST_LIST" | "$JQ" -r '.[1]' 2>/dev/null)
            AUTHOR_BLOCK="${A1}-${A2}"
        elif [[ "$NUMAUTH" -gt 2 ]]; then
            AUTHOR_BLOCK=$(echo "$AUTH_LAST_LIST" | "$JQ" -r '.[0]' 2>/dev/null)
        fi
    fi

    [[ -z "$AUTHOR_BLOCK" || "$AUTHOR_BLOCK" == "null" ]] && AUTHOR_BLOCK="Unknown"

    ###########################################################
    # CLEAN TITLE FOR FILENAME
    ###########################################################
    TITLE_CLEAN=$(echo "$TITLE" | tr ' ' '-' | tr -cd '[:alnum:]\-_' | cut -c1-50)
    [[ -z "$TITLE_CLEAN" ]] && TITLE_CLEAN="Untitled"

    ###########################################################
    # BUILD NEW PDF NAME
    ###########################################################
    NEWNAME="${AUTHOR_BLOCK}_${YEAR}_${TITLE_CLEAN}.pdf"
    NEWPATH="$DIR/$NEWNAME"
    FINAL_SUBDIR_LETTER=$(printf '%s' "$NEWNAME" | /usr/bin/cut -c1 | /usr/bin/tr '[:lower:]' '[:upper:]')

    if [[ ! "$FINAL_SUBDIR_LETTER" =~ ^[A-Z]$ ]]; then
        FINAL_SUBDIR_LETTER="_"
    fi

    FINAL_SUBDIR="$FINALDIR/$FINAL_SUBDIR_LETTER"

    if [[ -e "$NEWPATH" ]]; then
        NEWPATH="$DIR/${AUTHOR_BLOCK}_${YEAR}_${TITLE_CLEAN}_$(date +%s).pdf"
        NEWNAME=$(basename "$NEWPATH")
    fi

    mkdir -p "$FINAL_SUBDIR"
    FINAL_DEST="$FINAL_SUBDIR/$NEWNAME"
    if [[ -e "$FINAL_DEST" ]]; then
        UNIQUE_SUFFIX=$(date +%s)
        NEWNAME="${AUTHOR_BLOCK}_${YEAR}_${TITLE_CLEAN}_${UNIQUE_SUFFIX}.pdf"
        NEWPATH="$DIR/$NEWNAME"
        FINAL_DEST="$FINAL_SUBDIR/$NEWNAME"
    fi

    ###########################################################
    # RENAME THEN MOVE TO FINAL DIRECTORY
    ###########################################################
    if ! /bin/mv "$PDF" "$NEWPATH"; then
        echo "Warning: failed to rename $BASE; skipping" >&2
        continue
    fi

    if ! /bin/mv "$NEWPATH" "$FINAL_DEST"; then
        echo "Warning: failed to move $NEWNAME to $FINAL_DEST" >&2
        if [[ -f "$NEWPATH" ]]; then
            /bin/mv "$NEWPATH" "$PDF" 2>/dev/null || true
        fi
        continue
    fi

    ###########################################################
    # GENERATE RIS FILE
    ###########################################################
    RISFILE="${WATCHDIR}/${AUTHOR_BLOCK}_${YEAR}_${TITLE_CLEAN}.ris"
    cat <<EOF > "$RISFILE"
TY  - JOUR
TI  - $FULL_TITLE
T1  - $FULL_TITLE
JF  - $JOURNAL
JO  - $JOURNAL
PY  - $YEAR
VL  - $VOLUME
IS  - $ISSUE
SP  - $PAGES
DO  - $DOI
EOF

    if [[ -n "$DOI" && "$DOI" != "null" ]]; then
        echo "UR  - https://doi.org/$DOI" >> "$RISFILE"
    fi

    ###########################################################
    # RIS AUTHORS — GPT FORMATTED
    ###########################################################
    if [[ -z "$API_ERROR" ]]; then
        RIS_AUTHORS=$(echo "$CLEAN" | "$JQ" -r "$META .ris_authors" 2>/dev/null)

        if [[ "$RIS_AUTHORS" != "null" && -n "$RIS_AUTHORS" ]]; then
            echo "$RIS_AUTHORS" | "$JQ" -r '.[]' 2>/dev/null | while read -r author; do
                echo "AU  - $author" >> "$RISFILE"
            done
        fi
    fi

    echo "ER  -" >> "$RISFILE"
    echo "$PDF_HASH" >> "$PROCESSED_DB"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processed: $BASE -> $NEWNAME" >&2
done

    [[ "$PENDING_FOUND" -eq 0 ]] && break
done

# DONE