#!/bin/bash
#
# pdf_renamer.sh
# Automatically extract metadata from academic PDFs using the OpenAI API,
# rename the PDF, move it to a final folder, and generate a matching RIS file.
#
# -------------------------------------------------------
# ✏️ USER CONFIGURATION — EDIT THESE FOUR SETTINGS
# -------------------------------------------------------

# Folder to watch (launchd will monitor this folder)
WATCHDIR="$HOME/WatchFolder"

# Where renamed PDFs will be moved after processing
FINALDIR="$HOME/ProcessedPapers"

# Absolute paths to required executables
PDFTOTEXT="/usr/local/bin/pdftotext"
JQ="/opt/anaconda3/bin/jq"
CURL="/opt/anaconda3/bin/curl"

# -------------------------------------------------------
# END OF USER CONFIGURATION
# -------------------------------------------------------

# Ensure final folder exists
mkdir -p "$FINALDIR"

# Get the most recently updated PDF (WatchPaths does not pass filenames)
PDF=$(ls -t "$WATCHDIR"/*.pdf 2>/dev/null | head -n 1)

[[ -z "$PDF" ]] && exit 0

DIR=$(dirname "$PDF")
BASE=$(basename "$PDF")

# Safety
if [[ "$PDF" != *.pdf && "$PDF" != *.PDF ]]; then
    exit 0
fi

# Extract text
PDF_TEXT=$("$PDFTOTEXT" "$PDF" - 2>/dev/null)

# Build JSON prompt for OpenAI API
JSON=$("$JQ" -n --arg text "$PDF_TEXT" '
{
  "model": "gpt-4o-mini",
  "messages": [
    {
      "role": "system",
      "content": "Extract academic article metadata. Return ONLY raw JSON. Keys required: first_author_last, all_authors_last, authors_full, year, title, journal, volume, issue, pages, doi."
    },
    {
      "role": "user",
      "content": ("Extract article metadata from this PDF text. Return ONLY JSON.\n\nText:\n" + $text)
    }
  ]
}
')

# Call OpenAI API
RESPONSE=$("$CURL" -s https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d "$JSON")

# Save raw response for debugging
echo "$RESPONSE" > /tmp/pdf_renamer_last_response.json

# Remove any stray code fences
CLEAN=$(echo "$RESPONSE" \
    | sed 's/```json//g' \
    | sed 's/```//g')

# Parse metadata
AUTHOR=$("$JQ" -r '.choices[0].message.content | fromjson | .first_author_last' <<< "$CLEAN")
AUTHORS_FULL=$("$JQ" -r '.choices[0].message.content | fromjson | .authors_full' <<< "$CLEAN")
YEAR=$("$JQ" -r '.choices[0].message.content | fromjson | .year' <<< "$CLEAN")
TITLE=$("$JQ" -r '.choices[0].message.content | fromjson | .title' <<< "$CLEAN")
FULL_TITLE="$TITLE"
JOURNAL=$("$JQ" -r '.choices[0].message.content | fromjson | .journal' <<< "$CLEAN")
VOLUME=$("$JQ" -r '.choices[0].message.content | fromjson | .volume' <<< "$CLEAN")
ISSUE=$("$JQ" -r '.choices[0].message.content | fromjson | .issue' <<< "$CLEAN")
PAGES=$("$JQ" -r '.choices[0].message.content | fromjson | .pages' <<< "$CLEAN")
DOI=$("$JQ" -r '.choices[0].message.content | fromjson | .doi' <<< "$CLEAN")

# Determine filename authors block
AUTH_LAST_LIST=$("$JQ" -r '.choices[0].message.content | fromjson | .all_authors_last' <<< "$CLEAN")
NUMAUTH=$("$JQ" 'length' <<< "$AUTH_LAST_LIST")

if [[ "$NUMAUTH" -eq 1 ]]; then
    AUTHOR_BLOCK=$("$JQ" -r '.[0]' <<< "$AUTH_LAST_LIST")
elif [[ "$NUMAUTH" -eq 2 ]]; then
    A1=$("$JQ" -r '.[0]' <<< "$AUTH_LAST_LIST")
    A2=$("$JQ" -r '.[1]' <<< "$AUTH_LAST_LIST")
    AUTHOR_BLOCK="${A1}-${A2}"
else
    AUTHOR_BLOCK=$("$JQ" -r '.[0]' <<< "$AUTH_LAST_LIST")
fi

# Fallbacks
[[ "$YEAR" == "null" || "$YEAR" == "" ]] && YEAR="XXXX"
[[ "$TITLE" == "null" ]] && TITLE=""

if [[ -z "$AUTHOR" && "$YEAR" == "XXXX" && -z "$TITLE" ]]; then
    exit 0
fi

# Hyphenated title for filename
TITLE=$(echo "$TITLE" | tr ' ' '-' | tr -cd '[:alnum:]\-_' | cut -c1-50)

# New filename
NEWNAME="${AUTHOR_BLOCK}_${YEAR}_${TITLE}.pdf"
NEWPATH="$DIR/$NEWNAME"

# Collision handling
if [[ -e "$NEWPATH" ]]; then
    NEWPATH="$DIR/${AUTHOR_BLOCK}_${YEAR}_${TITLE}_$(date +%s).pdf"
fi

# Rename
mv "$PDF" "$NEWPATH"

# Move renamed PDF out of watched folder
mv "$NEWPATH" "$FINALDIR/"

# Create RIS file
RIS="${DIR}/${AUTHOR_BLOCK}_${YEAR}_${TITLE}.ris"

cat <<EOF > "$RIS"
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

# Add DOI URL
if [[ -n "$DOI" && "$DOI" != "null" ]]; then
    echo "UR  - https://doi.org/$DOI" >> "$RIS"
fi

# Add cleaned authors (Lastname, First Middle)
if [[ "$AUTHORS_FULL" != "null" ]]; then
    echo "$AUTHORS_FULL" | "$JQ" -r '.[]' | while read -r author; do

        clean=$(echo "$author" | sed -E 's/,?\s*(M\.?D\.?|Ph\.?D\.?|Sc\.?D\.?|Dr\.?)//gi')
        words=($clean)

        last="${words[-1]}"
        first_middle=""

        for ((i=0; i<${#words[@]}-1; i++)); do
            part=$(echo "${words[$i]}" | sed 's/[^A-Za-z]//g')
            if [[ -n "$part" ]]; then
                first_middle="$first_middle$part "
            fi
        done

        first_middle=$(echo "$first_middle" | sed 's/ *$//')
        formatted="$last, $first_middle"

        echo "AU  - $formatted" >> "$RIS"
    done
fi

echo "ER  -" >> "$RIS"
